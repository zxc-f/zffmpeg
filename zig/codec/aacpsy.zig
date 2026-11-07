// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/psymodel.c and psymodel.h (ff_psy_init,
// ff_psy_find_group, the context and window structures) and aacpsy.c (the
// 3GPP TS 26.403-inspired model and its LAME window decision) at the
// pinned reference revision.
// Copyright (C) 2008 Konstantin Shishkov
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's AAC encoder psychoacoustic model (`ff_aac_psy_model`, TODO.md
//! T32d), bit for bit: the 3GPP TS 26.403-inspired threshold analysis
//! (energies, spreading, threshold in quiet, pre-echo control, the
//! perceptual entropy and its reduction to the bit demand of the
//! reservoir, the quality modes and the signal-relative mask ceiling) and
//! the LAME-derived window decision (the fs/4 high-pass attack detector
//! with its novelty, HF and gap-onset checks, the block-type state machine
//! and level-homogeneous short-window grouping), alone or synchronized
//! across a channel pair.
//!
//! The encoder owns the model's inputs FFmpeg keeps in `FFPsyContext`:
//! `bitres.bits` before each `analyze`, `pair_joint` and `pair_decoupled`
//! between frames; it reads `bitres.size`, `bitres.alloc` and each
//! channel's `bands` and `entropy`. `analyze` takes the codec context's
//! `frame_num`: the rate loop may analyze a frame again under the same
//! number, and the carried state then rewinds to the frame's start as
//! FFmpeg's does. `psy_3gpp_window` (`av_unused` in FFmpeg) is not ported,
//! nor is `ff_psy_preprocess`, which aacenc.c does not call.

const std = @import("std");
const libm = @import("../core/libm.zig");
const cconv = @import("../core/cconv.zig");

/// PSY_MAX_BANDS: bands per channel, 16 per window of a short frame.
pub const max_bands = 128;

/// The lookahead `window` reads: aacenc.c passes `la` at sample 1536 of a
/// channel's 3 * 1024 sample buffer, and the detector reads its first 1056
/// samples (the high-pass filter's taps reach `la[11 + 1023 + 21]`).
pub const lookahead_len = 1056;

/// `enum WindowSequence`.
pub const WindowSequence = enum(u2) { only_long, long_start, eight_short, long_stop };

/// `FFPsyWindowInfo` (without `window_sizes`, which the AAC model never
/// sets). `window_type` holds the current and previous sequence; the third
/// is always `only_long`. The model leaves `clipping` zero: the encoder
/// fills it.
pub const WindowInfo = struct {
    window_type: [3]WindowSequence = @splat(.only_long),
    window_shape: u1 = 0,
    /// 1, or 8 for `eight_short`.
    num_windows: u4 = 0,
    /// Windows per group, the groups first.
    grouping: [8]u8 = @splat(0),
    clipping: [8]f32 = @splat(0),
};

/// `FFPsyBand`: one band of a channel's analysis.
pub const Band = struct {
    bits: i32 = 0,
    energy: f32 = 0,
    threshold: f32 = 0,
    /// Energy spread over the band.
    spread: f32 = 0,
};

/// What `ff_psy_init` reads from the codec context and its arguments.
pub const Config = struct {
    sample_rate: u32,
    channels: u8,
    bit_rate: i64,
    /// AV_CODEC_FLAG_QSCALE.
    qscale: bool = false,
    global_quality: i32 = 0,
    /// The analysis bandwidth in Hz: ff_psy_init's `cutoff`, or the codec
    /// context's when that is 0. 0 derives it (AAC_CUTOFF); a negative
    /// value is refused as FFmpeg refuses it.
    cutoff: i32,
    /// The quality-target coder's fixed-reference PE reduction.
    unbounded_pe: bool = false,
    /// Scalefactor band sizes of a long and of a short window
    /// (`ff_aac_swb_size_1024`/`_128` for the rate), borrowed for the
    /// model's lifetime. At most 64 long and 16 short bands, none empty,
    /// covering at most 1024 and 128 lines.
    band_sizes: [2][]const u8,
    /// The group map, one entry per channel element: channels in the
    /// group minus one (1 for a CPE, 0 otherwise). The groups cover
    /// `channels` exactly.
    groups: []const u8,
};

pub const InitError = error{ OutOfMemory, InvalidConfig };

/// A call that breaks the API's contract: a channel outside the model, an
/// element that does not start a group, or a window count other than 1
/// and 8.
pub const CallError = error{InvalidArgument};

/// The `bitres` part of `FFPsyContext`.
pub const Bitres = struct {
    /// Size of the bit reservoir in bits.
    size: i32 = 0,
    /// Bits used in the reservoir: the encoder's input to `analyze`.
    bits: i32 = 0,
    /// Bits the analysis allocated; the encoder sets -1 before `analyze`.
    alloc: i32 = 0,
};

// 3GPP model constants.
const thr_spread_hi: f32 = 1.5;
const thr_spread_low: f32 = 3.0;
const en_spread_hi_l1: f32 = 2.0;
const en_spread_hi_s: f32 = 1.5;
const en_spread_low_l: f32 = 3.0;
const en_spread_low_s: f32 = 2.0;
const rpemin: f32 = 0.01;
const rpelev: f32 = 2.0;
const c1: f32 = 3.0;
const c2: f32 = 1.3219281;
const c3: f32 = 0.55935729;
const snr_1db: f32 = 7.9432821e-1;
const snr_25db: f32 = 3.1622776e-3;
const thrfl_quality: f32 = 10.0;
const thrfl_cbr: f32 = 6.0;
const thrfl_cbr_knee: f32 = 8000.0;
const demand_scale: f32 = 2.5;
const ah_thr_long: f32 = 0.5;
const ah_thr_short: f32 = 0.63;
const pe_forget_slope = 511;
const bits_to_pe: f32 = 1.18;
const ath_add = 4;

// LAME window decision constants.
const fir_len = 21;
const block_long = 1024;
const block_short = 128;
const num_short = 8;
const num_sub = 2;
const pe_gap = 12;
const pe_quiet: f32 = 0.4;
const pe_red: f32 = 0.45;
const hist = 32;
const nov_back = 30;
const hfn_rel: f32 = 4.0;
const hfn_abs: f32 = 2000.0;
const hfn_pre: f32 = 8.0;
const gap_depth: f32 = 6.0;
const gap_back = 24;
const gap_level: f32 = 0.4;
const gap_floor: f32 = 4000.0;
const gap_tower: f32 = 4.0;
const grp_ratio: f32 = 2.5;
const grp_max = 4;

const subs = num_short * num_sub;
const sub_len = block_long / subs;

/// `psy_abr_map`: kbps per channel and the attack threshold (`st_lrm`).
const abr_map = [13]struct { quality: i32, st_lrm: f32 }{
    .{ .quality = 8, .st_lrm = 7.60 },   .{ .quality = 16, .st_lrm = 7.60 },  .{ .quality = 24, .st_lrm = 7.60 },
    .{ .quality = 32, .st_lrm = 7.60 },  .{ .quality = 40, .st_lrm = 7.60 },  .{ .quality = 48, .st_lrm = 7.60 },
    .{ .quality = 56, .st_lrm = 7.60 },  .{ .quality = 64, .st_lrm = 7.40 },  .{ .quality = 80, .st_lrm = 7.00 },
    .{ .quality = 96, .st_lrm = 6.60 },  .{ .quality = 112, .st_lrm = 6.20 }, .{ .quality = 128, .st_lrm = 6.20 },
    .{ .quality = 160, .st_lrm = 6.20 },
};

/// `psy_vbr_map`'s `st_lrm`, the same for every quality.
const vbr_st_lrm: f32 = 4.20;

/// `psy_fir_coeffs`: double products, stored as floats.
const fir_coeffs = [10]f32{
    @floatCast(@as(f64, -8.65163e-18) * 2), @floatCast(@as(f64, -0.00851586) * 2),
    @floatCast(@as(f64, -6.74764e-18) * 2), @floatCast(@as(f64, 0.0209036) * 2),
    @floatCast(@as(f64, -3.36639e-17) * 2), @floatCast(@as(f64, -0.0438162) * 2),
    @floatCast(@as(f64, -1.54175e-17) * 2), @floatCast(@as(f64, 0.0931738) * 2),
    @floatCast(@as(f64, -5.52212e-17) * 2), @floatCast(@as(f64, -0.313819) * 2),
};

const AvoidHoles = enum { none, inactive, active };

/// `AacPsyBand`.
const PsyBand = struct {
    energy: f32 = 0,
    thr: f32 = 0,
    thr_quiet: f32 = 0,
    nz_lines: f32 = 0,
    active_lines: f32 = 0,
    pe: f32 = 0,
    pe_const: f32 = 0,
    norm_fac: f32 = 0,
    avoid_holes: AvoidHoles = .none,
};

/// `AacPsyCoeffs`. `min_snr` changes during analysis: the further PE
/// reduction raises it for good, as FFmpeg's does.
const Coeffs = struct {
    ath: f32 = 0,
    barks: f32 = 0,
    spread_low: [2]f32 = @splat(0),
    spread_hi: [2]f32 = @splat(0),
    min_snr: f32 = 0,
};

/// One channel: `AacPsyChannel` (without psy_3gpp_window's state) and its
/// `FFPsyChannel`.
pub const Channel = struct {
    band: [max_bands]PsyBand = @splat(.{}),
    prev_band: [max_bands]PsyBand = @splat(.{}),
    next_grouping: u8 = 0,
    next_window_seq: WindowSequence = .only_long,
    attack_threshold: f32 = 0,
    prev_energy_subshort: [subs]f32 = @splat(10.0),
    next_win_level: [num_short]f32 = @splat(0),
    dif_env_hist: [hist]f32 = @splat(10.0),
    hp_env_hist: [hist]f32 = @splat(10.0),
    raw_env_hist: [hist]f32 = @splat(10.0),
    gap_wall: f32 = 0,
    gap_wall_hp: f32 = 0,
    prev_attack: i32 = 0,
    next_attack0_zero: bool = false,
    frames_since_short: i32 = 0,
    rc_frame_num: i64 = -1,
    rc_prev_band: [max_bands]PsyBand = @splat(.{}),
    /// The analysis's output: band `g` of window `w` at `w * 16 + g`.
    bands: [max_bands]Band = @splat(.{}),
    /// The channel's total perceptual entropy.
    entropy: f32 = 0,
};

/// The model: `FFPsyContext` with `AacPsyContext`.
pub const Psy = struct {
    gpa: std.mem.Allocator,
    sample_rate: i32,
    qscale: bool,
    global_quality: i32,
    unbounded_pe: bool,
    /// The analysis bandwidth: the configured cutoff, or AAC_CUTOFF.
    bandwidth: i32,
    band_sizes: [2][]const u8,
    /// Channels per group (owned).
    group_channels: []u8,
    /// Per channel (owned).
    channels: []Channel,
    coeffs: [2][64]Coeffs,
    chan_bitrate: i32,
    frame_bits: i32,
    fill_level: i32,
    pe_min: f32,
    pe_max: f32,
    pe_previous: f32 = 0,
    rc_frame_num: i64 = -1,
    rc_first_ch: usize = 0,
    rc_fill_level: i32 = 0,
    rc_pe_min: f32 = 0,
    rc_pe_max: f32 = 0,
    rc_pe_previous: f32 = 0,
    bitres: Bitres = .{},
    /// The encoder's per-CPE joint-tool candidacy average (`pair_joint`);
    /// the model does not read it.
    pair_joint: [16]f32 = @splat(0),
    /// The encoder's per-CPE state (`pair_decoupled`): nonzero lets the
    /// pair `(channel0 >> 1) & 15` window each channel on its own.
    pair_decoupled: [16]u8 = @splat(0),

    /// `ff_psy_init` with the AAC model's `psy_3gpp_init`.
    pub fn init(gpa: std.mem.Allocator, config: Config) InitError!Psy {
        if (config.channels == 0 or config.sample_rate == 0 or config.sample_rate > std.math.maxInt(i32))
            return error.InvalidConfig;
        const long = config.band_sizes[0];
        const short = config.band_sizes[1];
        if (long.len == 0 or long.len > 64 or short.len == 0 or short.len > 16) return error.InvalidConfig;
        if (sum(long) > block_long or sum(short) > block_short) return error.InvalidConfig;
        if (std.mem.findScalar(u8, long, 0) != null or std.mem.findScalar(u8, short, 0) != null) return error.InvalidConfig;
        var group_total: usize = 0;
        for (config.groups) |g| group_total += @as(usize, g) + 1;
        if (config.groups.len == 0 or group_total != config.channels) return error.InvalidConfig;

        const sample_rate: i32 = @intCast(config.sample_rate);
        const sr_f: f32 = @floatFromInt(sample_rate);
        const bandwidth: i32 = if (config.cutoff != 0) config.cutoff else aacCutoff(config);
        const num_bark = calcBark(@floatFromInt(bandwidth));
        if (bandwidth <= 0) return error.InvalidConfig;

        const divisor: f32 = if (config.qscale) 2.0 else @floatFromInt(config.channels);
        const bit_rate_f: f32 = @floatFromInt(config.bit_rate);
        var chan_bitrate = cvtt(bit_rate_f / divisor);
        if (config.qscale) {
            // Use the target average bit rate to compute spread parameters.
            const q: f64 = @floatFromInt(if (config.global_quality != 0) config.global_quality else 120);
            chan_bitrate = cconv.cvttsd2si32(@as(f64, @floatFromInt(chan_bitrate)) / 120.0 * q);
        }
        // C's int arithmetic wraps on the reference build (notes.md "Follow
        // the reference build"); a rate this large never reaches it from
        // the encoder.
        const frame_bits = ffminInt(2560, @divTrunc(chan_bitrate *% block_long, sample_rate));
        const bandwidth_f: f32 = @floatFromInt(bandwidth);
        const pe_min = 8.0 * @as(f32, block_long) * bandwidth_f / (sr_f * 2.0);
        const pe_max = 12.0 * @as(f32, block_long) * bandwidth_f / (sr_f * 2.0);
        var size: i32 = 6144 -% frame_bits;
        size -= @rem(size, 8);

        var coeffs: [2][64]Coeffs = @splat(@splat(.{}));
        const chan_bitrate_f: f32 = @floatFromInt(chan_bitrate);
        const ath_freq: f64 = 3410 - @as(f64, 0.733) * ath_add;
        const minath = ath(@floatCast(ath_freq), ath_add);
        for (0..2) |j| {
            const c = &coeffs[j];
            const sizes = config.band_sizes[j];
            const line_to_frequency: f32 = sr_f / @as(f32, if (j == 1) 256.0 else 2048.0);
            const avg_chan_bits: f32 = chan_bitrate_f * @as(f32, if (j == 1) 128.0 else 1024.0) / sr_f;
            // The reference encoder uses 2.4% here instead of 60% like the
            // spec says.
            const bark_pe: f32 = 0.024 * (avg_chan_bits * bits_to_pe) / num_bark;
            const en_spread_low = if (j == 1) en_spread_low_s else en_spread_low_l;
            // Compares the rate in bits per second with 22: only a rate
            // below 23 bit/s takes the low-rate long-block spreading.
            const en_spread_hi = if (j == 1 or chan_bitrate_f <= 22.0) en_spread_hi_s else en_spread_hi_l1;

            var line: i32 = 0;
            var prev: f32 = 0;
            for (sizes, 0..) |band_size, g| {
                line += band_size;
                const bark = calcBark(@as(f32, @floatFromInt(line - 1)) * line_to_frequency);
                c[g].barks = @floatCast(@as(f64, bark + prev) / 2.0);
                prev = bark;
            }
            for (0..sizes.len - 1) |g| {
                // FFmpeg measures every width from the first band
                // (`coeffs->barks`, not `coeff->barks`).
                const bark_width = c[g + 1].barks - c[0].barks;
                c[g].spread_low[0] = @floatCast(exp10(-bark_width * thr_spread_low));
                c[g].spread_hi[0] = @floatCast(exp10(-bark_width * thr_spread_hi));
                c[g].spread_low[1] = @floatCast(exp10(-bark_width * en_spread_low));
                c[g].spread_hi[1] = @floatCast(exp10(-bark_width * en_spread_hi));
                const pe_min_band = bark_pe * bark_width;
                const minsnr: f32 = @floatCast(libm.exp2(pe_min_band / @as(f32, @floatFromInt(sizes[g]))) - 1.5);
                c[g].min_snr = clipf(1.0 / minsnr, snr_25db, snr_1db);
            }
            var start: i32 = 0;
            for (sizes, 0..) |band_size, g| {
                var minscale = ath(@as(f32, @floatFromInt(start)) * line_to_frequency, ath_add);
                for (1..band_size) |i| {
                    const freq = @as(f32, @floatFromInt(start + @as(i32, @intCast(i)))) * line_to_frequency;
                    minscale = ffmin(minscale, ath(freq, ath_add));
                }
                c[g].ath = minscale - minath;
                start += band_size;
            }
        }

        const group_channels = try gpa.alloc(u8, config.groups.len);
        errdefer gpa.free(group_channels);
        for (group_channels, config.groups) |*n, g| n.* = g + 1;
        const channels = try gpa.alloc(Channel, config.channels);
        errdefer comptime unreachable;

        // lame_window_init: quality-target coders (VBR and ABR) switch
        // windows for quality, not rate, so they use the quality map.
        const attack_threshold = if (config.qscale or config.unbounded_pe)
            vbr_st_lrm
        else
            // C narrows the int64 quotient to the int parameter.
            lameAttackThreshold(@truncate(@divTrunc(@divTrunc(config.bit_rate, config.channels), 1000)));
        for (channels) |*ch| ch.* = .{ .attack_threshold = attack_threshold };

        return .{
            .gpa = gpa,
            .sample_rate = sample_rate,
            .qscale = config.qscale,
            .global_quality = config.global_quality,
            .unbounded_pe = config.unbounded_pe,
            .bandwidth = bandwidth,
            .band_sizes = config.band_sizes,
            .group_channels = group_channels,
            .channels = channels,
            .coeffs = coeffs,
            .chan_bitrate = chan_bitrate,
            .frame_bits = frame_bits,
            .fill_level = size,
            .pe_min = pe_min,
            .pe_max = pe_max,
            .bitres = .{ .size = size },
        };
    }

    pub fn deinit(p: *Psy) void {
        p.gpa.free(p.channels);
        p.gpa.free(p.group_channels);
        p.* = undefined;
    }

    /// Channel `channel`'s bands after its last analysis.
    pub fn bands(p: *const Psy, channel: usize) *const [max_bands]Band {
        return &p.channels[channel].bands;
    }

    /// Channel `channel`'s total perceptual entropy after its last analysis.
    pub fn entropy(p: *const Psy, channel: usize) f32 {
        return p.channels[channel].entropy;
    }

    /// The window decision for one channel (`psy_lame_window`). `la` is
    /// the lookahead (`planar_samples[ch] + 1536`), null at the flush;
    /// `prev_type` the channel's previous `window_type[0]`.
    pub fn window(p: *Psy, la: ?*const [lookahead_len]f32, channel: usize, prev_type: WindowSequence) CallError!WindowInfo {
        if (channel >= p.channels.len) return error.InvalidArgument;
        const pch = &p.channels[channel];
        var attacks: [num_short + 1]i32 = @splat(0);
        const use_long = detect(pch, la, prev_type, &attacks);
        return apply(pch, use_long, &attacks, prev_type, la != null);
    }

    /// The window decision for a channel pair (`psy_lame_window_pair`):
    /// either channel's attack switches both, with one grouping, unless
    /// `pair_decoupled` says the pair's joint tools are dead.
    pub fn windowPair(
        p: *Psy,
        la0: ?*const [lookahead_len]f32,
        la1: ?*const [lookahead_len]f32,
        channel0: usize,
        channel1: usize,
        prev_type0: WindowSequence,
        prev_type1: WindowSequence,
    ) CallError![2]WindowInfo {
        if (channel0 >= p.channels.len or channel1 >= p.channels.len) return error.InvalidArgument;
        const pch0 = &p.channels[channel0];
        const pch1 = &p.channels[channel1];
        var att0: [num_short + 1]i32 = @splat(0);
        var att1: [num_short + 1]i32 = @splat(0);
        const use_long0 = detect(pch0, la0, prev_type0, &att0);
        const use_long1 = detect(pch1, la1, prev_type1, &att1);

        if (p.pair_decoupled[(channel0 >> 1) & 15] != 0) {
            // Joint tools are dead on this pair: each channel windows for
            // its own transients.
            const w0 = apply(pch0, use_long0, &att0, prev_type0, la0 != null);
            const w1 = apply(pch1, use_long1, &att1, prev_type1, la1 != null);
            return .{ w0, w1 };
        }

        // One merged attack map, and one level map, so the grouping (and
        // common_window) matches across the pair.
        var merged: [num_short + 1]i32 = undefined;
        for (&merged, att0, att1) |*m, a0, a1| m.* = if (a0 != 0) a0 else a1;
        for (&pch0.next_win_level, &pch1.next_win_level) |*l0, *l1| {
            const level = ffmax(l0.*, l1.*);
            l0.* = level;
            l1.* = level;
        }
        const use_long = use_long0 and use_long1;
        const w0 = apply(pch0, use_long, &merged, prev_type0, la0 != null);
        const w1 = apply(pch1, use_long, &merged, prev_type1, la1 != null);
        return .{ w0, w1 };
    }

    /// `psy_3gpp_analyze`: the bands of the element whose first channel is
    /// `first_channel`, from its channels' spectra and windows.
    /// `frame_num` is the codec context's: a second analysis of a frame
    /// under the same number rewinds the carried state first.
    pub fn analyze(
        p: *Psy,
        first_channel: usize,
        spectra: []const *const [block_long]f32,
        windows: []const WindowInfo,
        frame_num: i64,
    ) CallError!void {
        // ff_psy_find_group, restricted to a group's first channel.
        var group_start: usize = 0;
        const num_ch: usize = for (p.group_channels) |n| {
            if (group_start == first_channel) break n;
            group_start += n;
        } else return error.InvalidArgument;
        if (spectra.len != num_ch or windows.len != num_ch) return error.InvalidArgument;
        for (windows) |wi| if (wi.num_windows != 1 and wi.num_windows != 8) return error.InvalidArgument;

        // The rate loop may analyze a frame again; the carried state
        // advances once per frame, so it is saved on the frame's first run
        // and rewound on a re-run.
        if (frame_num != p.rc_frame_num) {
            p.rc_frame_num = frame_num;
            p.rc_first_ch = first_channel;
            p.rc_fill_level = p.fill_level;
            p.rc_pe_min = p.pe_min;
            p.rc_pe_max = p.pe_max;
            p.rc_pe_previous = p.pe_previous;
        } else if (first_channel == p.rc_first_ch) {
            p.fill_level = p.rc_fill_level;
            p.pe_min = p.rc_pe_min;
            p.pe_max = p.rc_pe_max;
            p.pe_previous = p.rc_pe_previous;
        }

        for (0..num_ch) |ch| {
            const pch = &p.channels[first_channel + ch];
            if (frame_num != pch.rc_frame_num) {
                pch.rc_frame_num = frame_num;
                pch.rc_prev_band = pch.prev_band;
            } else {
                pch.prev_band = pch.rc_prev_band;
            }
            p.analyzeChannel(pch, spectra[ch], &windows[ch]);
        }
    }

    /// psy_3gpp_analyze_channel.
    fn analyzeChannel(p: *Psy, pch: *Channel, coefs: *const [block_long]f32, wi: *const WindowInfo) void {
        const short = wi.num_windows == 8;
        const j: usize = @intFromBool(short);
        const num_windows: usize = wi.num_windows;
        const band_sizes = p.band_sizes[j];
        const num_bands = band_sizes.len;
        const coeffs = &p.coeffs[j];
        var spread_en: [max_bands]f32 = @splat(0);
        var a: f32 = 0;
        var active_lines: f32 = 0;
        var norm_fac: f32 = 0;
        var pe: f32 = if (p.chan_bitrate > 32000)
            0.0
        else
            ffmax(50.0, 100.0 - @as(f32, @floatFromInt(p.chan_bitrate)) * 100.0 / 32000.0);

        // Short-to-long band map for pre-echo control across the
        // transition from a start frame.
        var s2l: [16]u8 = @splat(0);
        const start_after_long = short and wi.window_type[1] == .long_start;
        if (start_after_long) {
            const ls = p.band_sizes[0];
            const ss = p.band_sizes[1];
            var lacc: i32 = 0;
            var sacc: i32 = 0;
            var gl: usize = 0;
            for (0..@min(num_bands, 16)) |gs| {
                const center8 = (sacc + ss[gs] / 2) * 8;
                while (gl < ls.len - 1 and lacc + ls[gl] <= center8) {
                    lacc += ls[gl];
                    gl += 1;
                }
                s2l[gs] = @intCast(gl);
                sacc += ss[gs];
            }
        }
        const avoid_hole_thr = if (short) ah_thr_short else ah_thr_long;
        // C's int arithmetic wraps on the reference build (notes.md "Follow
        // the reference build"); no bandwidth the encoder sets reaches it.
        const cutoff = @divTrunc(@divTrunc(p.bandwidth *% 2048, @as(i32, wi.num_windows)), p.sample_rate);

        // 5.4.2 "Threshold Calculation": energies, initial thresholds.
        var start: usize = 0;
        for (0..num_windows) |w| {
            var wstart: i32 = 0;
            for (band_sizes, 0..) |band_size, g| {
                const band = &pch.band[w * 16 + g];
                var form_factor: f32 = 0;
                band.energy = 0;
                if (wstart < cutoff) {
                    for (coefs[start..][0..band_size]) |c| {
                        band.energy += c * c;
                        form_factor += @sqrt(@abs(c));
                    }
                }
                const size_f: f32 = @floatFromInt(band_size);
                const temp: f32 = if (band.energy > 0) @sqrt(size_f / band.energy) else 0;
                band.thr = band.energy * 0.001258925;
                band.nz_lines = form_factor * @sqrt(temp);
                start += band_size;
                wstart += band_size;
            }
        }

        // Spreading, threshold in quiet, pre-echo control.
        for (0..num_windows) |w| {
            const bands_w = pch.band[w * 16 ..][0..num_bands];
            const spread_w = spread_en[w * 16 ..][0..num_bands];
            spread_w[0] = bands_w[0].energy;
            for (1..num_bands) |g| {
                bands_w[g].thr = ffmax(bands_w[g].thr, bands_w[g - 1].thr * coeffs[g].spread_hi[0]);
                spread_w[g] = ffmax(bands_w[g].energy, spread_w[g - 1] * coeffs[g].spread_hi[1]);
            }
            var g = num_bands - 1;
            while (g > 0) {
                g -= 1;
                bands_w[g].thr = ffmax(bands_w[g].thr, bands_w[g + 1].thr * coeffs[g].spread_low[0]);
                spread_w[g] = ffmax(spread_w[g], spread_w[g + 1] * coeffs[g].spread_low[1]);
            }
            for (bands_w, 0..) |*band, gi| {
                band.thr = ffmax(band.thr, coeffs[gi].ath);
                band.thr_quiet = band.thr;
                if (!(wi.window_type[0] == .long_stop or (w == 0 and wi.window_type[1] == .long_start))) {
                    band.thr = ffmax(rpemin * band.thr, ffmin(band.thr, rpelev * pch.prev_band[w * 16 + gi].thr_quiet));
                } else if (w == 0 and start_after_long) {
                    // Window 0 after a start frame: the grid-mapped, scaled
                    // continuity clamp instead of the spec's skip.
                    const prev = pch.prev_band[s2l[@min(gi, 15)]].thr;
                    band.thr = ffmax(rpemin * band.thr, ffmin(band.thr, rpelev * prev / 8.0));
                }

                // 5.6.1.3.1 "Preparatory steps of the perceptual entropy
                // calculation".
                pe += calcPe(band);
                a += band.pe_const;
                active_lines += band.active_lines;

                // 5.6.1.3.3 "Selection of the bands for avoidance of holes".
                band.avoid_holes = if (spread_w[gi] * avoid_hole_thr > band.energy or coeffs[gi].min_snr > 1.0)
                    .none
                else
                    .inactive;
            }
        }

        // 5.6.1.3.2 "Calculation of the desired perceptual entropy".
        pch.entropy = pe;
        var desired_bits: f32 = undefined;
        var desired_pe: f32 = undefined;
        if (p.unbounded_pe) {
            // The quality-target coder: the reduction runs at a fixed
            // reference quality.
            desired_pe = pe * 120.0 / pe_quality_scale;
            desired_bits = ffmin(2560.0, desired_pe / bits_to_pe);
            desired_pe = desired_bits * bits_to_pe;
            p.pe_max = ffmax(pe, p.pe_max);
            p.pe_min = ffmin(pe, p.pe_min);
        } else if (p.qscale) {
            const q: f32 = @floatFromInt(if (p.global_quality != 0) p.global_quality else 120);
            desired_pe = pe * q / pe_quality_scale;
            desired_bits = ffmin(2560.0, desired_pe / bits_to_pe);
            desired_pe = desired_bits * bits_to_pe;
            if (p.bitres.bits > 0) {
                desired_bits = ffmin(2560.0, desired_pe / bits_to_pe);
                desired_pe = desired_bits * bits_to_pe;
            }
            p.pe_max = ffmax(pe, p.pe_max);
            p.pe_min = ffmin(pe, p.pe_min);
        } else {
            desired_bits = @floatFromInt(p.calcBitDemand(pe, p.bitres.bits, p.bitres.size, short));
            desired_pe = desired_bits * bits_to_pe;
            if (p.bitres.bits > 0) {
                const bits_pe = @as(f32, @floatFromInt(p.bitres.bits)) * bits_to_pe;
                desired_pe *= clipf(p.pe_previous / bits_pe, inv_1_15, 1.15);
            }
        }
        p.pe_previous = desired_bits * bits_to_pe;
        p.bitres.alloc = cvtt(desired_bits);

        if (desired_pe < pe) {
            // 5.6.1.3.4 "First Estimation of the reduction value". Each
            // window's reduction comes from the previous window's sums.
            var reduction: f32 = std.math.nan(f32);
            for (0..num_windows) |w| {
                reduction = calcReduction(a, desired_pe, pe, active_lines);
                pe = 0;
                a = 0;
                active_lines = 0;
                for (pch.band[w * 16 ..][0..num_bands], 0..) |*band, g| {
                    band.thr = calcReducedThr(band, coeffs[g].min_snr, reduction);
                    pe += calcPe(band);
                    a += band.pe_const;
                    active_lines += band.active_lines;
                }
            }

            // 5.6.1.3.5 "Second Estimation of the reduction value";
            // norm_fac sums over both passes.
            var delta_pe: f32 = undefined;
            for (0..2) |_| {
                var pe_no_ah: f32 = 0;
                active_lines = 0;
                a = 0;
                for (0..num_windows) |w| {
                    for (pch.band[w * 16 ..][0..num_bands]) |*band| {
                        if (band.avoid_holes != .active) {
                            pe_no_ah += band.pe;
                            a += band.pe_const;
                            active_lines += band.active_lines;
                        }
                    }
                }
                const desired_pe_no_ah = ffmax(desired_pe - (pe - pe_no_ah), 0.0);
                if (active_lines > 0.0) reduction = calcReduction(a, desired_pe_no_ah, pe_no_ah, active_lines);

                pe = 0;
                for (0..num_windows) |w| {
                    for (pch.band[w * 16 ..][0..num_bands], 0..) |*band, g| {
                        if (active_lines > 0.0) band.thr = calcReducedThr(band, coeffs[g].min_snr, reduction);
                        pe += calcPe(band);
                        band.norm_fac = if (band.thr > 0.0) band.active_lines / band.thr else 0.0;
                        norm_fac += band.norm_fac;
                    }
                }
                delta_pe = desired_pe - pe;
                if (@abs(delta_pe) > 0.05 * desired_pe) break;
            }

            if (pe < 1.15 * desired_pe) {
                // 6.6.1.3.6 "Final threshold modification by linearization".
                norm_fac = if (norm_fac != 0) 1.0 / norm_fac else 0;
                for (0..num_windows) |w| {
                    for (pch.band[w * 16 ..][0..num_bands], 0..) |*band, g| {
                        if (band.active_lines > 0.5) {
                            const delta_sfb_pe = band.norm_fac * norm_fac * delta_pe;
                            var thr = band.thr;
                            thr *= libm.exp2f(delta_sfb_pe / band.active_lines);
                            if (thr > coeffs[g].min_snr * band.energy and band.avoid_holes == .inactive)
                                thr = ffmax(band.thr, coeffs[g].min_snr * band.energy);
                            band.thr = thr;
                        }
                    }
                }
            } else {
                // 5.6.1.3.7 "Further perceptual entropy reduction". The
                // raised min_snr stays in the table for later frames, as
                // FFmpeg's does.
                var g = num_bands;
                while (pe > desired_pe and g != 0) {
                    g -= 1;
                    for (0..num_windows) |w| {
                        const band = &pch.band[w * 16 + g];
                        if (band.avoid_holes != .none and coeffs[g].min_snr < snr_1db) {
                            coeffs[g].min_snr = snr_1db;
                            band.thr = band.energy * snr_1db;
                            pe += band.active_lines * 1.5 - band.pe;
                        }
                    }
                }
            }
        }

        // The signal-relative mask ceiling: a coded band never gets noise
        // within PSY_THRFL_* dB of its own energy.
        {
            const qmode = p.unbounded_pe or p.qscale;
            const lim = if (qmode) thrfl_quality else thrfl_cbr;
            const knee: f32 = if (qmode) 0.0 else thrfl_cbr_knee;
            const lo = exp10f(-lim / 10.0);
            const l2f = @as(f32, @floatFromInt(p.sample_rate)) / 2.0 / @as(f32, if (num_windows == 1) 1024.0 else 128.0);
            for (0..num_windows) |w| {
                var line: i32 = 0;
                for (pch.band[w * 16 ..][0..num_bands], band_sizes) |*band, band_size| {
                    if (@as(f32, @floatFromInt(line)) * l2f >= knee) band.thr = ffmin(band.thr, band.energy * lo);
                    line += band_size;
                }
            }
        }

        for (0..num_windows) |w| {
            for (pch.band[w * 16 ..][0..num_bands], pch.bands[w * 16 ..][0..num_bands], band_sizes) |band, *out, band_size| {
                out.threshold = band.thr;
                out.energy = band.energy;
                out.spread = band.active_lines * 2.0 / @as(f32, @floatFromInt(band_size));
                out.bits = cvtt(band.pe / bits_to_pe);
            }
        }
        pch.prev_band = pch.band;
    }

    /// calc_bit_demand: 5.6.1.2 "Calculation of Bit Demand".
    fn calcBitDemand(p: *Psy, pe: f32, bits: i32, size: i32, short: bool) i32 {
        const bitsave_slope: f32 = if (short) -0.36363637 else -0.46666667;
        const bitsave_add: f32 = if (short) -0.75 else -0.84285712;
        const bitspend_slope: f32 = if (short) 0.81818181 else 0.66666669;
        const bitspend_add: f32 = if (short) -0.26111111 else -0.35;
        const clip_low: f32 = 0.2;
        const clip_high: f32 = if (short) 0.75 else 0.95;

        // C's int arithmetic wraps on the reference build (notes.md "Follow
        // the reference build"); `bits` is the encoder's.
        p.fill_level +%= p.frame_bits -% bits;
        p.fill_level = clipInt(p.fill_level, 0, size);
        const fill_level = clipf(@as(f32, @floatFromInt(p.fill_level)) / @as(f32, @floatFromInt(size)), clip_low, clip_high);
        const clipped_pe = clipf(pe, p.pe_min, p.pe_max);
        const bit_save = (fill_level + bitsave_add) * bitsave_slope;
        const bit_spend = (fill_level + bitspend_add) * bitspend_slope;
        var bit_factor = 1.0 - bit_save + ((bit_spend - bit_save) / (p.pe_max - p.pe_min)) * (clipped_pe - p.pe_min);
        bit_factor = 1.0 + (bit_factor - 1.0) * demand_scale;
        // Slowly forget pe.min while the PE stays above it.
        p.pe_max = ffmax(pe, p.pe_max);
        const forgetful_min_pe = ((p.pe_min * pe_forget_slope) + ffmax(p.pe_min, pe * (pe / p.pe_max))) / (pe_forget_slope + 1);
        p.pe_min = ffmin(pe, forgetful_min_pe);

        // Allocate at least 1/8 of the average frame bits.
        const frame_bits_f: f32 = @floatFromInt(p.frame_bits);
        const floor: f32 = @floatFromInt(@max(p.frame_bits +% size -% bits, @divTrunc(p.frame_bits, 8)));
        return cvtt(ffmin(frame_bits_f * bit_factor, floor));
    }
};

/// `2 * 2.5f * 120.0f`: the quality modes' PE divisor.
const pe_quality_scale: f32 = 2 * @as(f32, 2.5) * 120.0;
/// `1.0f / 1.15f`.
const inv_1_15: f32 = @as(f32, 1.0) / @as(f32, 1.15);
/// M_LOG2_10.
const log2_10: f64 = 3.32192809488736234787;

fn sum(sizes: []const u8) usize {
    var total: usize = 0;
    for (sizes) |s| total += s;
    return total;
}

/// AAC_CUTOFF on the configuration.
fn aacCutoff(config: Config) i32 {
    const sr: i64 = config.sample_rate;
    if (config.qscale or config.bit_rate == 0) return @intCast(@divTrunc(sr, 2));
    // C's int64 arithmetic wraps on the reference build (notes.md "Follow
    // the reference build").
    const per_channel = @divTrunc(config.bit_rate, config.channels);
    const a = @max(@divTrunc(per_channel, 5), @divTrunc(per_channel *% 15, 32) -% 5500);
    const b = 3000 +% @divTrunc(per_channel, 4);
    const c = 12000 +% @divTrunc(per_channel, 16);
    const cutoff = @min(@min(@min(a, b), c), 22000, @divTrunc(sr, 2));
    // C narrows the int64 result to the int `bandwidth`.
    return @truncate(cutoff);
}

/// lame_calc_attack_threshold.
fn lameAttackThreshold(bitrate: i32) f32 {
    var lower: usize = 12;
    var upper: usize = 12;
    var lower_kbps = abr_map[12].quality;
    var upper_kbps = abr_map[12].quality;
    for (1..13) |i| {
        if (abr_map[i].quality > bitrate) {
            upper = i;
            upper_kbps = abr_map[i].quality;
            lower = i - 1;
            lower_kbps = abr_map[i - 1].quality;
            break;
        }
    }
    // C's int arithmetic wraps on the reference build (notes.md "Follow the
    // reference build").
    if ((upper_kbps -% bitrate) > (bitrate -% lower_kbps)) return abr_map[lower].st_lrm;
    return abr_map[upper].st_lrm;
}

/// calc_bark.
fn calcBark(f: f32) f32 {
    return 13.3 * libm.atanf(0.00076 * f) + 3.5 * libm.atanf((f / 7500.0) * (f / 7500.0));
}

/// ath: computed in double, from the float frequency in kHz.
fn ath(f_hz: f32, add: f32) f32 {
    const f: f64 = f_hz / 1000.0;
    const d1 = f - 3.4;
    const d2 = f - 8.7;
    const add_d: f64 = add;
    return @floatCast(3.64 * libm.pow(f, -0.8) -
        6.8 * libm.exp(-0.6 * d1 * d1) +
        6.0 * libm.exp(-0.15 * d2 * d2) +
        (0.6 + 0.04 * add_d) * 0.001 * f * f * f * f);
}

/// ff_exp10: exp2 of the double product.
fn exp10(x: f32) f64 {
    return libm.exp2(log2_10 * @as(f64, x));
}

/// ff_exp10f: M_LOG2_10 is a double, so the product is one, rounded to
/// float for exp2f.
fn exp10f(x: f32) f32 {
    return libm.exp2f(@floatCast(log2_10 * @as(f64, x)));
}

/// FFMAX and FFMIN on floats, as the C macros compare (a NaN picks `b`).
fn ffmax(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

fn ffmin(a: f32, b: f32) f32 {
    return if (a > b) b else a;
}

fn ffminInt(a: i32, b: i32) i32 {
    return if (a > b) b else a;
}

/// av_clipf: FFMIN(FFMAX(a, min), max), NaN giving `min`.
fn clipf(a: f32, min: f32, max: f32) f32 {
    return ffmin(ffmax(a, min), max);
}

/// av_clip.
fn clipInt(a: i32, min: i32, max: i32) i32 {
    return if (a < min) min else if (a > max) max else a;
}

/// A float stored into an int: `cvttss2si`, NaN and overflow giving
/// `minInt(i32)`.
fn cvtt(x: f32) i32 {
    return cconv.cvttsd2si32(x);
}

/// calc_pe_3gpp.
fn calcPe(band: *PsyBand) f32 {
    band.pe = 0;
    band.pe_const = 0;
    band.active_lines = 0;
    if (band.energy > band.thr) {
        var a = libm.log2f(band.energy);
        var pe = a - libm.log2f(band.thr);
        band.active_lines = band.nz_lines;
        if (pe < c1) {
            pe = pe * c3 + c2;
            a = a * c3 + c2;
            band.active_lines *= c3;
        }
        band.pe = pe * band.nz_lines;
        band.pe_const = a * band.nz_lines;
    }
    return band.pe;
}

/// calc_reduction_3gpp.
fn calcReduction(a: f32, desired_pe: f32, pe: f32, active_lines: f32) f32 {
    if (active_lines == 0.0) return 0;
    const thr_avg = libm.exp2f((a - pe) / (4.0 * active_lines));
    const reduction = libm.exp2f((a - desired_pe) / (4.0 * active_lines)) - thr_avg;
    return ffmax(reduction, 0.0);
}

/// calc_reduced_thr_3gpp. Deviates from the 3GPP spec to match the
/// reference encoder: the min(thr_reduced, max(thr, energy/min_snr)) rule
/// applies only to bands with hole avoidance on.
fn calcReducedThr(band: *PsyBand, min_snr: f32, reduction: f32) f32 {
    var thr = band.thr;
    if (band.energy > thr) {
        thr = @sqrt(thr);
        thr = @sqrt(thr) + reduction;
        thr *= thr;
        thr *= thr;
        if (thr > band.energy * min_snr and band.avoid_holes != .none) {
            thr = ffmax(band.thr, band.energy * min_snr);
            band.avoid_holes = .active;
        }
    }
    return thr;
}

/// psy_hp_filter: the fs/4 high pass, scaled to LAME's 16-bit range.
fn hpFilter(firbuf: *const [block_long + fir_len]f32, out: *[block_long]f32) void {
    for (out, 0..) |*o, i| {
        var sum1 = firbuf[i + (fir_len - 1) / 2];
        var sum2: f32 = 0;
        var j: usize = 0;
        while (j < (fir_len - 1) / 2 - 1) : (j += 2) {
            sum1 += fir_coeffs[j] * (firbuf[i + j] + firbuf[i + fir_len - j]);
            sum2 += fir_coeffs[j + 1] * (firbuf[i + j + 1] + firbuf[i + fir_len - j - 1]);
        }
        o.* = (sum1 + sum2) * 32768.0;
    }
}

/// psy_lame_detect: the attack detection half of the LAME window
/// decision. Fills `attacks` and returns whether a long block may stay;
/// changes only the channel's detection history.
fn detect(pch: *Channel, la_opt: ?*const [lookahead_len]f32, prev_type: WindowSequence, attacks: *[num_short + 1]i32) bool {
    // Without lookahead the previous sequence's kind stays.
    const la = la_opt orelse return prev_type != .eight_short;

    var hpfsmpl: [block_long]f32 = undefined;
    var attack_intensity: [(num_short + 1) * num_sub]f32 = undefined;
    var energy_subshort: [(num_short + 1) * num_sub]f32 = undefined;
    var energy_short: [num_short + 1]f32 = @splat(0);
    var att_sum: i32 = 0;

    // LAME: apply a high-pass filter of fs/4.
    hpFilter(la[block_short / 4 - fir_len ..][0 .. block_long + fir_len], &hpfsmpl);

    // The energies of each sub-short block.
    for (0..num_sub) |i| {
        energy_subshort[i] = pch.prev_energy_subshort[i + (num_short - 1) * num_sub];
        attack_intensity[i] = energy_subshort[i] / pch.prev_energy_subshort[i + (num_short - 1) * num_sub - 2];
        energy_short[0] += energy_subshort[i];
    }
    for (0..subs) |i| {
        var p: f32 = 1.0;
        for (hpfsmpl[i * sub_len ..][0..sub_len]) |x| p = ffmax(p, @abs(x));
        pch.prev_energy_subshort[i] = p;
        energy_subshort[i + num_sub] = p;
        energy_short[1 + i / num_sub] += p;

        // LAME's [i + 3 - 2]: each sub-block against sub-block - 2.
        const before = energy_subshort[i + num_sub - 2];
        if (p > before) {
            p = p / before;
        } else if (before > p * 10.0) {
            p = before / (p * 10.0);
        } else {
            p = 0.0;
        }
        attack_intensity[i + num_sub] = p;
    }
    for (&pch.next_win_level, energy_short[1..]) |*level, e| level.* = e;

    {
        // Pre-echo-aware threshold relaxation and the periodicity check:
        // a pulse train repeats its peak, a real onset towers.
        var frame_peak: f32 = 1.0;
        var env: [hist + subs]f32 = undefined;
        var denv: [hist + subs]f32 = undefined;
        const nov_gate: f32 = 1.25;
        // The first-difference peak of each sub-block.
        denv[0..hist].* = pch.dif_env_hist;
        for (0..subs) |i| {
            var p: f32 = 0;
            for (i * sub_len + 1..(i + 1) * sub_len) |j2| p = ffmax(p, @abs(la[j2] - la[j2 - 1]));
            denv[hist + i] = ffmax(p * 32768.0, 1.0);
        }
        pch.dif_env_hist = denv[subs..][0..hist].*;
        env[0..hist].* = pch.hp_env_hist;
        env[hist..].* = energy_subshort[num_sub..].*;
        for (energy_subshort[num_sub..]) |e| frame_peak = ffmax(frame_peak, e);
        for (0..(num_short + 1) * num_sub) |i| {
            if (attacks[i / num_sub] != 0) continue;
            var thr = pch.attack_threshold;
            if (i >= num_sub and pch.frames_since_short >= pe_gap and
                energy_subshort[i - num_sub] < pe_quiet * frame_peak)
                thr *= pe_red;
            if (!(attack_intensity[i] > thr)) continue;
            if (i >= num_sub) {
                // An attack must tower over the recent HP envelope: within
                // about 12 ms always, within about 44 ms from steady
                // long-window state.
                const pos = hist + i - num_sub;
                var nearmax: f32 = 1.0;
                var deepmax: f32 = 1.0;
                for (3..9) |k| nearmax = ffmax(nearmax, env[pos - k]);
                for (3..nov_back + 1) |k| deepmax = ffmax(deepmax, env[pos - k]);
                if (energy_subshort[i] < nov_gate * nearmax or
                    (energy_subshort[i] < nov_gate * deepmax and pch.frames_since_short >= pe_gap))
                    continue; // periodic, not an onset
            }
            if (i >= num_sub) {
                // No HF novelty and masked pre-echo: the candidate stays
                // long.
                const pos = hist + i - num_sub;
                var dmax: f32 = 1.0;
                var premin: f32 = 1e30;
                for (1..nov_back + 1) |k| dmax = ffmax(dmax, denv[pos - k]);
                for (1..5) |k| premin = ffmin(premin, env[pos - k]);
                if (denv[pos] < hfn_rel * dmax and denv[pos] < hfn_abs and premin * hfn_pre > energy_subshort[i])
                    continue;
            }
            attacks[i / num_sub] = @intCast(i % num_sub + 1);
        }
    }

    // An energy change between short blocks is required, to avoid periodic
    // signals.
    for (1..num_short + 1) |i| {
        const u = energy_short[i - 1];
        const v = energy_short[i];
        const m = ffmax(u, v);
        if (m < 40000) {
            if (u < 2.3 * v and v < 2.3 * u) {
                if (i == 1 and attacks[0] < attacks[i]) attacks[0] = 0;
                attacks[i] = 0;
            }
        }
        att_sum += attacks[i];
    }

    {
        // Gap-onset detection on the broadband and the HP envelope: a
        // candidate that towers over a recent dip.
        var renv: [hist + subs]f32 = undefined;
        var henv: [hist + subs]f32 = undefined;
        renv[0..hist].* = pch.raw_env_hist;
        for (0..subs) |i| {
            var p: f32 = 0;
            for (la[i * 64 ..][0..64]) |x| p = ffmax(p, @abs(x));
            renv[hist + i] = ffmax(p * 32768.0, 1.0);
        }
        henv[0..hist].* = pch.hp_env_hist;
        henv[hist..].* = energy_subshort[num_sub..].*;
        const walls = [2]*f32{ &pch.gap_wall, &pch.gap_wall_hp };
        const envs = [2]*const [hist + subs]f32{ &renv, &henv };
        for (walls, envs, 0..) |wall_ptr, ev, e| {
            var wall = wall_ptr.*;
            for (0..subs) |i| {
                const b = (i + num_sub) / num_sub;
                const pos = hist + i;
                const cand = ev[pos];
                const quiet = wall / gap_depth;
                var run: i32 = 0;
                var k0: usize = 0;
                // The gap ends next to the candidate and holds at least 4
                // sub-blocks.
                for (3..9) |k| {
                    if (ev[pos - k] < quiet) {
                        k0 = k;
                        break;
                    }
                }
                if (k0 != 0) {
                    var k = k0;
                    while (k <= gap_back and ev[pos - k] < quiet) : (k += 1) run += 1;
                }
                if (e == 1 and !(run >= 4)) {
                    // HP tower: an onset far above the whole look-back.
                    var dmax: f32 = 1.0;
                    for (3..gap_back + 1) |k| dmax = ffmax(dmax, ev[pos - k]);
                    if (cand > gap_tower * dmax) run = 4;
                }
                if (attacks[b] == 0 and run >= 4 and cand > gap_level * wall and cand > gap_floor) {
                    attacks[b] = @intCast((i + num_sub) % num_sub + 1);
                    att_sum += attacks[b];
                }
                wall = ffmax(wall * 0.996, cand);
            }
            wall_ptr.* = wall;
        }
        pch.raw_env_hist = renv[subs..][0..hist].*;
    }

    // Roll the HP sub-block peak history.
    pch.hp_env_hist[0 .. hist - subs].* = pch.hp_env_hist[subs..][0 .. hist - subs].*;
    pch.hp_env_hist[hist - subs ..].* = energy_subshort[num_sub..].*;

    if (pch.next_attack0_zero) attacks[0] = 0;
    pch.next_attack0_zero = attacks[num_short] == 0;
    if (attacks[0] <= pch.prev_attack) attacks[0] = 0;
    att_sum += attacks[0];

    // A short window if the previous attack was in the previous sequence's
    // last sub-block, or on a new attack.
    if (pch.prev_attack == num_sub or att_sum != 0) {
        for (1..num_short + 1) |i| {
            if (attacks[i] != 0 and attacks[i - 1] != 0) attacks[i] = 0;
        }
        return false;
    }
    return true;
}

/// lame_apply_block_type.
fn applyBlockType(pch: *Channel, wi: *WindowInfo, use_long: bool) void {
    var block_type: WindowSequence = .only_long;
    if (use_long) {
        if (pch.next_window_seq == .eight_short) block_type = .long_stop;
    } else {
        block_type = .eight_short;
        if (pch.next_window_seq == .only_long) pch.next_window_seq = .long_start;
        if (pch.next_window_seq == .long_stop) pch.next_window_seq = .eight_short;
    }
    wi.window_type[0] = pch.next_window_seq;
    pch.next_window_seq = block_type;
}

/// psy_lame_apply: the block-type state machine and the window and
/// grouping fill, from the (possibly pair-synchronized) decision.
fn apply(pch: *Channel, use_long: bool, attacks: *const [num_short + 1]i32, prev_type: WindowSequence, have_la: bool) WindowInfo {
    var wi: WindowInfo = .{};
    // C's int arithmetic wraps on the reference build (notes.md "Follow the
    // reference build").
    if (have_la) pch.frames_since_short = if (use_long) pch.frames_since_short +% 1 else 0;
    applyBlockType(pch, &wi, use_long);
    wi.window_type[1] = prev_type;
    if (wi.window_type[0] != .eight_short) {
        wi.num_windows = 1;
        wi.grouping[0] = 1;
        wi.window_shape = if (wi.window_type[0] == .long_start) 0 else 1;
    } else {
        var lastgrp: usize = 0;
        wi.num_windows = 8;
        wi.window_shape = 0;
        for (0..8) |i| {
            if ((pch.next_grouping >> @intCast(i)) & 1 == 0) lastgrp = i;
            wi.grouping[lastgrp] += 1;
        }
    }

    // FFmpeg first stores window_grouping[] of the first attack's
    // position, then overwrites it with the level-homogeneous grouping
    // below, so the attack position never reaches the next frame.

    // Group adjacent windows whose levels are within PSY_LAME_GRP_RATIO.
    var grouping_bits: u8 = 0;
    var glen: i32 = 1;
    for (1..num_short) |i| {
        const a = pch.next_win_level[i];
        const b = pch.next_win_level[i - 1];
        const hi = ffmax(a, b);
        const lo = ffmax(ffmin(a, b), 1.0);
        if (hi <= lo * grp_ratio and glen < grp_max) {
            grouping_bits |= @as(u8, 1) << @intCast(i);
            glen += 1;
        } else {
            glen = 1;
        }
    }
    pch.next_grouping = grouping_bits;
    pch.prev_attack = attacks[num_short - 1];
    return wi;
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;
const signals = @import("../testing/signals.zig");
const aac_tab = @import("aac_tab.zig");
const hostile = @import("../testing/hostile.zig");

/// aacpsy_vectors.c's `sample`: signals.zig's signals, plus `gap`,
/// `click` and `soft`; then its `fsample`.
fn vectorSample(rng: *signals.Rng, signal: []const u8, gain: f32, specials: bool, c: usize, i: usize, state: *[8]i32) f32 {
    const own = for ([_][]const u8{ "gap", "click", "soft" }) |name| {
        if (std.mem.eql(u8, signal, name)) break true;
    } else false;
    const v: i32 = if (own) v: {
        const noise: i32 = @as(i32, @intCast(rng.next() & 0xffff)) - 0x8000;
        if (std.mem.eql(u8, signal, "gap"))
            break :v if ((i + 300 * c) % 16384 >= 14336) noise else @divTrunc(noise, 512);
        if (std.mem.eql(u8, signal, "click"))
            break :v if ((i + 97 * c) % 1777 < 8) 30000 else @divTrunc(noise, 64);
        break :v if ((i + 211 * c) % 1500 < 100) @divTrunc(noise, 64) else @divTrunc(noise, 384);
    } else signals.sample(rng, signal, c, i, state, 16);
    if (specials) {
        if (i % 397 == 11) return std.math.nan(f32);
        if (i % 401 == 23) return if (c & 1 != 0) -std.math.inf(f32) else std.math.inf(f32);
        if (i % 409 == 37) return 1e30;
    }
    return @as(f32, @floatFromInt(v)) * (gain / 32768.0);
}

/// aacpsy_vectors.c's `spectrum`.
fn vectorSpectrum(rng: *signals.Rng, out: *[block_long]f32, kind: usize, gain: f32, specials: bool) void {
    for (out, 0..) |*o, k| {
        const n: f32 = @floatFromInt(@as(i32, @intCast(rng.next() & 0xffff)) - 0x8000);
        var v: f32 = switch (kind) {
            0 => 0.0,
            1 => n * (gain / @as(f32, @floatFromInt(k + 8))),
            2 => if (k % 37 == 5) n * 4.0 else n * (1.0 / 65536.0),
            3 => n * 1000.0,
            else => if (k < 64) n * 0.25 else 0.0,
        };
        if (specials and kind != 0) {
            if (k % 211 == 7) {
                v = std.math.nan(f32);
            } else if (k % 223 == 9) {
                v = std.math.inf(f32);
            }
        }
        o.* = v;
    }
}

/// `ff_aac_swb_size_1024`/`_128` for a rate, from the decoder's band
/// offsets.
fn vectorBandSizes(rate: u32, storage: *[2][64]u8) [2][]const u8 {
    const rates = [13]u32{ 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 };
    const index = std.mem.findScalar(u32, &rates, rate).?;
    const offsets = [2][]const u16{ aac_tab.swb_offset_1024[index], aac_tab.swb_offset_128[index] };
    const counts = [2]usize{ aac_tab.num_swb_1024[index], aac_tab.num_swb_128[index] };
    var out: [2][]const u8 = undefined;
    for (offsets, counts, storage, &out) |offs, count, *s, *o| {
        for (s[0..count], 0..) |*size, g| size.* = @intCast(offs[g + 1] - offs[g]);
        o.* = s[0..count];
    }
    return out;
}

fn hex(f: f32) u32 {
    return @bitCast(f);
}

fn renderWindow(w: *std.Io.Writer, ch: usize, wi: WindowInfo) !void {
    try w.print("W {d} {d} {d} {d} {d} {d}", .{
        ch,
        @backingInt(wi.window_type[0]),
        @backingInt(wi.window_type[1]),
        @backingInt(wi.window_type[2]),
        wi.window_shape,
        wi.num_windows,
    });
    for (wi.grouping) |g| try w.print(" {d}", .{g});
    for (wi.clipping) |c| try w.print(" {x:0>8}", .{hex(c)});
    try w.writeAll("\n");
}

/// aacpsy_vectors.c's output for every case of `vectors`, rendered from
/// the port.
fn renderVectors(gpa: std.mem.Allocator, w: *std.Io.Writer, vectors: []const u8) !void {
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "C ")) continue;
        try w.print("{s}\n", .{line});
        var f = std.mem.tokenizeScalar(u8, line[2..], ' ');
        _ = f.next(); // name
        const rate = try std.fmt.parseInt(u32, f.next().?, 10);
        const elements = f.next().?;
        const bit_rate = try std.fmt.parseInt(i64, f.next().?, 10);
        const qscale = (try std.fmt.parseInt(u1, f.next().?, 10)) != 0;
        const global_quality = try std.fmt.parseInt(i32, f.next().?, 10);
        const unbounded = (try std.fmt.parseInt(u1, f.next().?, 10)) != 0;
        const cutoff = try std.fmt.parseInt(i32, f.next().?, 10);
        const avctx_cutoff = try std.fmt.parseInt(i32, f.next().?, 10);
        const frames = try std.fmt.parseInt(usize, f.next().?, 10);
        const signal = f.next().?;
        const gain: f32 = @floatFromInt(try std.fmt.parseInt(u32, f.next().?, 10));
        const specials = (try std.fmt.parseInt(u1, f.next().?, 10)) != 0;
        const decoupled = (try std.fmt.parseInt(u1, f.next().?, 10)) != 0;

        var groups: [16]u8 = undefined;
        var channels: usize = 0;
        for (elements, groups[0..elements.len]) |e, *g| {
            g.* = @intFromBool(e == 'P');
            channels += @as(usize, g.*) + 1;
        }
        var size_storage: [2][64]u8 = undefined;
        var psy = Psy.init(gpa, .{
            .sample_rate = rate,
            .channels = @intCast(channels),
            .bit_rate = bit_rate,
            .qscale = qscale,
            .global_quality = global_quality,
            .cutoff = if (cutoff != 0) cutoff else avctx_cutoff,
            .unbounded_pe = unbounded,
            .band_sizes = vectorBandSizes(rate, &size_storage),
            .groups = groups[0..elements.len],
        }) catch |err| switch (err) {
            error.InvalidConfig => {
                try w.writeAll("O EINVAL\n");
                continue;
            },
            else => |other| return other,
        };
        defer psy.deinit();
        try w.print("O ok\nB {d}\n", .{psy.bitres.size});

        const buf = try gpa.alloc([3 * block_long]f32, channels);
        defer gpa.free(buf);
        @memset(buf, @splat(0));
        const coef = try gpa.alloc([block_long]f32, channels);
        defer gpa.free(coef);
        var wi: [16]WindowInfo = @splat(.{});
        var prev_type: [16]WindowSequence = @splat(.only_long);
        var state: [8]i32 = @splat(0);
        var rng: signals.Rng = .{ .state = 0x9E3779B9 ^ @as(u32, @intCast(channels * 1000003 + frames)) };
        for (0..frames) |frame| {
            const last = frame == frames - 1;
            try w.print("F {d}\n", .{frame});
            for (buf) |*b| {
                b[block_long .. 2 * block_long].* = b[2 * block_long ..].*;
                @memset(b[2 * block_long ..], 0);
            }
            if (!last) {
                for (0..block_long) |i| {
                    for (buf, 0..) |*b, c| b[2 * block_long + i] = vectorSample(&rng, signal, gain, specials, c, frame * block_long + i, &state);
                }
            }
            const frame_num: i64 = @intCast(frame + 1);
            if (decoupled) psy.pair_decoupled = @splat(@intCast((frame / 2) & 1));

            var start: usize = 0;
            for (elements) |tag| {
                const chans: usize = if (tag == 'P') 2 else 1;
                if (tag == 'L') {
                    wi[start] = .{ .window_shape = 0, .num_windows = 1 };
                    wi[start].grouping[0] = 1;
                } else if (chans == 2 and !last) {
                    const pair = try psy.windowPair(
                        buf[start][1536..][0..lookahead_len],
                        buf[start + 1][1536..][0..lookahead_len],
                        start,
                        start + 1,
                        prev_type[start],
                        prev_type[start + 1],
                    );
                    wi[start] = pair[0];
                    wi[start + 1] = pair[1];
                } else {
                    for (start..start + chans) |c| {
                        const la: ?*const [lookahead_len]f32 = if (last) null else buf[c][1536..][0..lookahead_len];
                        wi[c] = try psy.window(la, c, prev_type[c]);
                    }
                }
                for (start..start + chans) |c| {
                    prev_type[c] = wi[c].window_type[0];
                    try renderWindow(w, c, wi[c]);
                }
                start += chans;
            }

            for (coef, 0..) |*c, ch| vectorSpectrum(&rng, c, (frame + ch) % 5, gain, specials);

            // The rate loop's re-runs: every element again, same frame_num.
            const passes: usize = if (frame % 3 == 1) 2 else if (frame % 5 == 3) 3 else 1;
            for (0..passes) |pass| {
                start = 0;
                for (elements) |tag| {
                    const chans: usize = if (tag == 'P') 2 else 1;
                    var spectra: [2]*const [block_long]f32 = undefined;
                    for (spectra[0..chans], coef[start..][0..chans]) |*s, *c| s.* = c;
                    psy.bitres.alloc = -1;
                    psy.bitres.bits = @intCast((frame * 7919 + start * 1009 + pass * 331) % 4500);
                    try psy.analyze(start, spectra[0..chans], wi[start..][0..chans], frame_num);
                    try w.print("A {d} {d} {d} {d}\n", .{ pass, start, psy.bitres.bits, psy.bitres.alloc });
                    for (start..start + chans) |c| {
                        const num_bands = psy.band_sizes[@intFromBool(wi[c].num_windows == 8)].len;
                        try w.print("N {d} {x:0>8}", .{ c, hex(psy.entropy(c)) });
                        for (0..wi[c].num_windows) |win| {
                            for (psy.bands(c)[win * 16 ..][0..num_bands]) |b| {
                                try w.print(" {d},{x:0>8},{x:0>8},{x:0>8}", .{ b.bits, hex(b.energy), hex(b.threshold), hex(b.spread) });
                            }
                        }
                        try w.writeAll("\n");
                    }
                    start += chans;
                }
            }
        }
    }
}

test "every case analyzes as FFmpeg's AAC psy model analyzes it (vectors/aacpsy.txt)" {
    const vectors = @embedFile("../testing/vectors/aacpsy.txt");
    var rendered: std.Io.Writer.Allocating = .init(testing.allocator);
    defer rendered.deinit();
    try renderVectors(testing.allocator, &rendered.writer, vectors);
    try testing.expectEqualStrings(vectors, rendered.written());
}

/// The 48 kHz bands.
const test_long = [_]u8{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 8, 8, 8, 8, 8, 8, 8, 12, 12, 12, 12, 16, 16, 20, 20, 24, 24, 28, 28 } ++
    @as([19]u8, @splat(32)) ++ [_]u8{96};
const test_short = [_]u8{ 4, 4, 4, 4, 4, 8, 8, 8, 12, 12, 12, 16, 16, 16 };

fn testConfig(groups: []const u8, channels: u8) Config {
    return .{
        .sample_rate = 48000,
        .channels = channels,
        .bit_rate = 128000,
        .cutoff = 16000,
        .band_sizes = .{ &test_long, &test_short },
        .groups = groups,
    };
}

test "the model refuses configurations it cannot index" {
    try testing.expectError(error.InvalidConfig, Psy.init(testing.allocator, testConfig(&.{0}, 2)));
    try testing.expectError(error.InvalidConfig, Psy.init(testing.allocator, testConfig(&.{}, 1)));
    var c = testConfig(&.{0}, 1);
    c.cutoff = -1;
    try testing.expectError(error.InvalidConfig, Psy.init(testing.allocator, c));
    c = testConfig(&.{0}, 1);
    c.band_sizes[1] = &(test_short ++ test_short);
    try testing.expectError(error.InvalidConfig, Psy.init(testing.allocator, c));
    c = testConfig(&.{0}, 1);
    c.band_sizes[0] = &(test_long ++ test_long);
    try testing.expectError(error.InvalidConfig, Psy.init(testing.allocator, c));
    c = testConfig(&.{0}, 1);
    c.band_sizes[1] = &.{ 4, 0, 4 };
    try testing.expectError(error.InvalidConfig, Psy.init(testing.allocator, c));
    c = testConfig(&.{0}, 1);
    c.sample_rate = 0;
    try testing.expectError(error.InvalidConfig, Psy.init(testing.allocator, c));
}

test "calls outside the model's channels and groups are refused" {
    var psy = try Psy.init(testing.allocator, testConfig(&.{ 0, 1 }, 3));
    defer psy.deinit();
    const la: [lookahead_len]f32 = @splat(0);
    try testing.expectError(error.InvalidArgument, psy.window(&la, 3, .only_long));
    try testing.expectError(error.InvalidArgument, psy.windowPair(&la, &la, 1, 3, .only_long, .only_long));
    const spectrum: [block_long]f32 = @splat(0);
    const long: WindowInfo = .{ .num_windows = 1 };
    // Channel 2 is inside the CPE that starts at channel 1.
    try testing.expectError(error.InvalidArgument, psy.analyze(2, &.{&spectrum}, &.{long}, 1));
    try testing.expectError(error.InvalidArgument, psy.analyze(1, &.{&spectrum}, &.{long}, 1));
    try testing.expectError(error.InvalidArgument, psy.analyze(0, &.{&spectrum}, &.{.{ .num_windows = 2 }}, 1));
    try psy.analyze(0, &.{&spectrum}, &.{long}, 1);
    try psy.analyze(1, &.{ &spectrum, &spectrum }, &.{ long, long }, 1);
}

fn initUnderFailures(gpa: std.mem.Allocator, channels: u8) !void {
    const groups = [_]u8{ 0, 1, 1, 0 };
    var psy = try Psy.init(gpa, testConfig(&groups, channels));
    defer psy.deinit();
    const la: [lookahead_len]f32 = @splat(0.25);
    _ = try psy.window(&la, 0, .only_long);
}

test "the model frees everything under every allocation failure" {
    try hostile.checkAllocationFailuresWith(testing.allocator, .both, @as(u8, 6), initUnderFailures);
}
