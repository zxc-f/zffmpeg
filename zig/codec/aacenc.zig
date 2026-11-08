// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/aacenc.c, aacenc.h, aacenctab.h and
// audio_frame_queue.c (the flush's sample count) at the pinned reference
// revision.
// Copyright (C) 2008 Konstantin Shishkov
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's AAC-LC encoder (`aac`, TODO.md T32d1 and T32d2) with its three
//! coders, `nmr` (the default, aaccoder_nmr.zig), `twoloop` and `fast`:
//! window decisions and the psychoacoustic model (aacpsy.zig), the
//! sine/KBD-windowed MDCT, clip avoidance, the coders' scalefactor searches
//! (aaccoder.zig), TNS (aacenc_tns.zig), PNS, mid/side and intensity
//! stereo, the section, scalefactor and spectral data, and the rate control
//! loop over lambda, packet for packet. Planar float samples in frames of
//! 1024 per channel, in FFmpeg's layout order; one frame of delay, so a
//! stream ends with flush packets.

const std = @import("std");
const aac_tab = @import("aac_tab.zig");
const enc_tab = @import("aacenc_tab.zig");
const aacpsy = @import("aacpsy.zig");
const coder = @import("aaccoder.zig");
const nmr_coder = @import("aaccoder_nmr.zig");
const tns_mod = @import("aacenc_tns.zig");
const tx = @import("tx.zig");
const float_dsp = @import("float_dsp.zig");
const bits = @import("bits.zig");
const libm = @import("../core/libm.zig");
const cconv = @import("../core/cconv.zig");
const options_zig = @import("../core/options.zig");
const pce_tab = @import("aacenc_pce.zig");

/// The samples a frame codes, per channel (`avctx->frame_size`).
pub const frame_samples = 1024;
/// `avctx->initial_padding`.
pub const initial_padding = 1024;
/// AAC_MAX_CHANNELS.
pub const max_channels = 16;

pub const scale_div_512 = 36;
pub const scale_one_pos = 140;
pub const scale_max_pos = 255;
pub const scale_max_diff = 60;
pub const scale_diff_zero = 60;
pub const pow_sf2_zero = 200;
const noise_pre = 256;
const noise_pre_bits = 9;
const noise_offset = 90;
/// CLIP_AVOIDANCE_FACTOR.
const clip_avoidance_factor: f32 = 0.95;

/// enum BandType.
pub const BandType = struct {
    pub const zero = 0;
    pub const first_pair = 5;
    pub const esc = 11;
    pub const reserved = 12;
    pub const noise = 13;
    pub const intensity2 = 14;
    pub const intensity = 15;
};

/// enum RawDataBlockType.
pub const ElementType = struct {
    pub const sce = 0;
    pub const cpe = 1;
    pub const lfe = 3;
    pub const fil = 6;
    pub const end = 7;
};

pub const WindowSequence = aacpsy.WindowSequence;
pub const PsyBand = aacpsy.Band;

/// IndividualChannelStream.
pub const Ics = struct {
    max_sfb: u8 = 0,
    window_sequence: [2]WindowSequence = .{ .only_long, .only_long },
    use_kb_window: [2]u1 = .{ 0, 0 },
    group_len: [8]u8 = @splat(0),
    swb_offset: []const u16 = &.{},
    swb_sizes: []const u8 = &.{},
    num_swb: u8 = 0,
    num_windows: u8 = 0,
    tns_max_bands: u8 = 0,
    window_clipping: [8]u8 = @splat(0),
    clip_avoidance_factor: f32 = 0,
};

/// TemporalNoiseShaping.
pub const Tns = struct {
    present: bool = false,
    n_filt: [8]i32 = @splat(0),
    length: [8][4]i32 = @splat(@splat(0)),
    direction: [8][4]i32 = @splat(@splat(0)),
    order: [8][4]i32 = @splat(@splat(0)),
    coef_idx: [8][4][tns_mod.max_order]i32 = @splat(@splat(@splat(0))),
    coef: [8][4][tns_mod.max_order]f32 = @splat(@splat(@splat(0))),
};

/// SingleChannelElement (the pulse tool is never used: no pulses).
pub const Sce = struct {
    ics: Ics = .{},
    tns: Tns = .{},
    band_type: [128]u8 = @splat(0),
    band_alt: [128]u8 = @splat(0),
    sf_idx: [128]i32 = @splat(0),
    zeroes: [128]u8 = @splat(0),
    can_pns: [128]u8 = @splat(0),
    is_ener: [128]f32 = @splat(0),
    pns_ener: [128]f32 = @splat(0),
    pcoeffs: [1024]f32 = @splat(0),
    coeffs: [1024]f32 = @splat(0),
    ret_buf: [2048]f32 = @splat(0),
};

/// ChannelElement.
pub const Cpe = struct {
    common_window: bool = false,
    ms_mode: i32 = 0,
    is_mode: u8 = 0,
    ms_mask: [128]u8 = @splat(0),
    is_mask: [128]u8 = @splat(0),
    ch: [2]Sce = .{ .{}, .{} },
};

/// AACQuantizeBandCostCacheEntry.
pub const CostCacheEntry = struct {
    rd: f32 = 0,
    energy: f32 = 0,
    bits: i32 = 0,
    cb: u8 = 0,
    rtz: bool = false,
    generation: u16 = 0,
};

/// The coders (`aac_coder`).
pub const Coder = enum(i32) { twoloop = 0, fast = 1, nmr = 2 };

/// AV_PROFILE_AAC_LOW, AV_PROFILE_MPEG2_AAC_LOW, AV_PROFILE_UNKNOWN.
pub const profile_aac_low = 1;
pub const profile_mpeg2_aac_low = 128;
pub const profile_unknown = -99;

/// The encoder's options: aacenc_options with their defaults, and the
/// codec context's bit rate, cutoff, quality and profile.
pub const Options = struct {
    /// `-b:a` in bit/s; 0 takes 128 kbit/s a pair, 69 a single channel and
    /// 16 an LFE.
    bit_rate: i64 = 0,
    /// `-cutoff` in Hz; 0 derives the bandwidth from the bit rate.
    cutoff: i32 = 0,
    /// `-q:a`'s `global_quality` (AV_CODEC_FLAG_QSCALE when `qscale`).
    global_quality: i32 = 0,
    qscale: bool = false,
    coder: Coder = .nmr,
    /// `aac_ms`: -1 searches, 0 off, 1 forced.
    mid_side: i32 = -1,
    intensity_stereo: i32 = 1,
    pns: i32 = 1,
    tns: i32 = 1,
    pce: i32 = 0,
    rc: i32 = 0,
    nmr_speed: i32 = 0,
    allow_71wide: bool = false,
    profile: i32 = profile_unknown,

    /// The ffmpeg program's `-q:a` (ffmpeg_mux_init.c): from 0 up,
    /// AV_CODEC_FLAG_QSCALE and `global_quality = FF_QP2LAMBDA * q`, the
    /// double stored into the int as the reference build converts it.
    pub fn setQuality(o: *Options, q: f64) void {
        if (!(q >= 0)) return;
        o.qscale = true;
        o.global_quality = cconv.cvttsd2si32(118.0 * q);
    }

    const int_min: f64 = std.math.minInt(i32);
    const int_max: f64 = std.math.maxInt(i32);

    /// aacenc_options, the codec context's `b`, `cutoff`, `profile` (with
    /// FF_AAC_PROFILE_OPTS) and `global_quality`, and the QSCALE flag the
    /// program's `-q:a` sets with it.
    pub const option_specs = [_]options_zig.Spec{
        .{ .name = "b", .field = "bit_rate", .kind = .int64, .help = "set bitrate (in bits/s)", .min = 0, .max = @floatFromInt(std.math.maxInt(i64)) },
        .{ .name = "cutoff", .field = "cutoff", .kind = .int, .help = "set cutoff bandwidth", .min = int_min, .max = int_max },
        .{ .name = "global_quality", .field = "global_quality", .kind = .int, .help = "", .min = int_min, .max = int_max },
        .{ .name = "qscale", .field = "qscale", .kind = .bool, .help = "AV_CODEC_FLAG_QSCALE", .min = 0, .max = 1 },
        .{ .name = "aac_coder", .field = "coder", .kind = .int, .help = "Coding algorithm", .min = 0, .max = 2, .constants = &.{
            .{ .name = "twoloop", .value = 0 }, .{ .name = "fast", .value = 1 }, .{ .name = "nmr", .value = 2 },
        } },
        .{ .name = "aac_ms", .field = "mid_side", .kind = .bool, .help = "Force M/S stereo coding", .min = -1, .max = 1 },
        .{ .name = "aac_is", .field = "intensity_stereo", .kind = .bool, .help = "Intensity stereo coding", .min = -1, .max = 1 },
        .{ .name = "aac_pns", .field = "pns", .kind = .bool, .help = "Perceptual noise substitution", .min = -1, .max = 1 },
        .{ .name = "aac_tns", .field = "tns", .kind = .bool, .help = "Temporal noise shaping", .min = -1, .max = 1 },
        .{ .name = "aac_pce", .field = "pce", .kind = .bool, .help = "Forces the use of PCEs", .min = -1, .max = 1 },
        .{ .name = "aac_rc", .field = "rc", .kind = .int, .help = "Rate-control mode (NMR coder)", .min = 0, .max = 1, .constants = &.{
            .{ .name = "cbr", .value = 0 }, .{ .name = "abr", .value = 1 },
        } },
        .{ .name = "aac_nmr_speed", .field = "nmr_speed", .kind = .int, .help = "NMR coder speed level", .min = 0, .max = 4 },
        .{ .name = "aac_allow_71wide", .field = "allow_71wide", .kind = .bool, .help = "Allow non-PCE use of 7.1(wide) channel layout", .min = 0, .max = 1 },
        .{ .name = "profile", .field = "profile", .kind = .int, .help = "", .min = int_min, .max = int_max, .constants = &.{
            .{ .name = "aac_main", .value = 0 },       .{ .name = "aac_low", .value = profile_aac_low },
            .{ .name = "aac_ssr", .value = 2 },        .{ .name = "aac_ltp", .value = 3 },
            .{ .name = "aac_he", .value = 4 },         .{ .name = "aac_he_v2", .value = 28 },
            .{ .name = "aac_ld", .value = 22 },        .{ .name = "aac_eld", .value = 38 },
            .{ .name = "aac_xhe", .value = 41 },       .{ .name = "mpeg2_aac_low", .value = profile_mpeg2_aac_low },
            .{ .name = "mpeg2_aac_he", .value = 131 },
        } },
    };

    comptime {
        options_zig.check(Options);
    }
};

pub const Error = error{
    /// A sample rate not in the MPEG-4 table, or a layout FFmpeg's encoder
    /// has no configuration for ("Unsupported channel layout", EINVAL).
    UnsupportedFormat,
    /// A profile the encoder does not take.
    InvalidOption,
    OutOfMemory,
};

pub const FrameError = error{
    /// More samples than a frame, or planes of the wrong count.
    InvalidFrame,
    /// "Input contains (near) NaN/+-Inf" (EINVAL).
    InvalidInput,
};

/// `ff_mpeg4audio_sample_rates`.
pub const sample_rates = [13]u32{ 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 };

const Layout = struct { mask: u64, chcfg: u8 };
/// aac_normal_chan_layouts: the layouts coded without a PCE, by their
/// channel configuration.
const normal_layouts = [_]Layout{
    .{ .mask = 0x4, .chcfg = 1 },
    .{ .mask = 0x3, .chcfg = 2 },
    .{ .mask = 0x7, .chcfg = 3 },
    .{ .mask = 0x107, .chcfg = 4 },
    .{ .mask = 0x37, .chcfg = 5 },
    .{ .mask = 0x3f, .chcfg = 6 },
    .{ .mask = 0xff, .chcfg = 7 },
    .{ .mask = 0x13f, .chcfg = 11 },
    .{ .mask = 0x63f, .chcfg = 12 },
    .{ .mask = 0x503f, .chcfg = 14 },
};

/// aac_chan_configs[chcfg - 1]: the element count, then each element.
const chan_configs = [14][6]u8{
    .{ 1, ElementType.sce, 0, 0, 0, 0 },
    .{ 1, ElementType.cpe, 0, 0, 0, 0 },
    .{ 2, ElementType.sce, ElementType.cpe, 0, 0, 0 },
    .{ 3, ElementType.sce, ElementType.cpe, ElementType.sce, 0, 0 },
    .{ 3, ElementType.sce, ElementType.cpe, ElementType.cpe, 0, 0 },
    .{ 4, ElementType.sce, ElementType.cpe, ElementType.cpe, ElementType.lfe, 0 },
    .{ 5, ElementType.sce, ElementType.cpe, ElementType.cpe, ElementType.cpe, ElementType.lfe },
    @splat(0),
    @splat(0),
    @splat(0),
    .{ 5, ElementType.sce, ElementType.cpe, ElementType.cpe, ElementType.sce, ElementType.lfe },
    .{ 5, ElementType.sce, ElementType.cpe, ElementType.cpe, ElementType.cpe, ElementType.lfe },
    @splat(0),
    .{ 5, ElementType.sce, ElementType.cpe, ElementType.cpe, ElementType.lfe, ElementType.cpe },
};

/// aac_chan_maps[chcfg - 1]: each AAC channel's input channel.
const chan_maps = [14][max_channels]u8{
    @splat(0),
    .{ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 0, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 0, 1, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 0, 1, 4, 5, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 6, 7, 0, 1, 4, 5, 3, 0, 0, 0, 0, 0, 0, 0, 0 },
    @splat(0),
    @splat(0),
    @splat(0),
    .{ 2, 0, 1, 4, 5, 6, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 0, 1, 6, 7, 4, 5, 3, 0, 0, 0, 0, 0, 0, 0, 0 },
    @splat(0),
    .{ 2, 0, 1, 4, 5, 3, 6, 7, 0, 0, 0, 0, 0, 0, 0, 0 },
};

/// AAC_CUTOFF_FROM_BITRATE.
fn cutoffFromBitrate(bit_rate: i32, channels: i32, sample_rate: i32) i32 {
    if (bit_rate == 0) return @divTrunc(sample_rate, 2);
    const bc = @divTrunc(bit_rate, channels);
    const a = @max(@divTrunc(bc, 5), @divTrunc(bc * 15, 32) - 5500);
    const b = 3000 + @divTrunc(bc, 4);
    const c = 12000 + @divTrunc(bc, 16);
    return @min(@min(@min(@min(a, b), c), 22000), @divTrunc(sample_rate, 2));
}

pub const Encoder = struct {
    gpa: std.mem.Allocator,
    opt: Options,
    /// `avctx->bit_rate` after opening, in bit/s.
    bit_rate: i64,
    sample_rate: u32,
    samplerate_index: u8,
    channels: u8,
    profile: i32,
    chcfg: u8,
    reorder_map: []const u8,
    /// The element count, then each element's type.
    chan_map: []const u8,
    /// The layout's program configuration element, when it takes one.
    pce: ?*const pce_tab.Config,
    needs_height_ext: bool,
    bandwidth: i32,
    cpe: []Cpe,
    psy: aacpsy.Psy,
    mdct1024: tx.Mdct,
    mdct128: tx.Mdct,
    cur_channel: usize = 0,
    cur_type: u8 = 0,
    random_state: i32 = 0x1f2e3d4c,
    lambda: f32,
    last_frame_pb_count: i32 = 0,
    qcoefs: [96]i32 = @splat(0),
    scoefs: [1024]f32 = @splat(0),
    cost_cache_generation: u16 = 0,
    cost_cache: [256][128]CostCacheEntry = @splat(@splat(.{})),
    /// The `nmr` coder's state (owned), null for the other coders.
    nmr: ?*nmr_coder.State = null,
    esc_pow43: [1 << 13]f32,
    lpc_buffer: tns_mod.LpcBuffer = .{},
    /// planar_samples: per AAC channel, the overlap, the current block
    /// and the next.
    samples: [max_channels][3 * 1024]f32 = @splat(@splat(0)),
    /// avctx->frame_num as encode.c keeps it: a frame's count when the
    /// encoder runs, and during the drain the count after the first flush
    /// call, which every later flush call sees again.
    frame_num: i64 = 0,
    draining: bool = false,
    /// The frame queue's samples (audio_frame_queue.c).
    remaining_samples: i64 = initial_padding,
    got_frame: bool = false,
    /// The AudioSpecificConfig (`avctx->extradata`, at most 32 bytes).
    extradata_buf: [32]u8 = @splat(0),
    extradata_len: usize = 0,

    /// aac_encode_init, with avcodec_open2's check of the sample rate;
    /// `layout` a native channel mask in FFmpeg's order.
    pub fn init(gpa: std.mem.Allocator, sample_rate: u32, layout: u64, options: Options) Error!*Encoder {
        const sr_index: u8 = for (sample_rates, 0..) |r, i| {
            if (r == sample_rate) break @intCast(i);
        } else return error.UnsupportedFormat;
        // A channel configuration, unless the layout needs a PCE or the
        // options ask for one.
        var chcfg: u8 = 0;
        var needs_pce = true;
        for (normal_layouts) |l| {
            if (l.mask == layout) {
                chcfg = l.chcfg;
                needs_pce = options.pce != 0;
                break;
            }
        }
        // FFmpeg used to mistag 7.1 as 7.1(wide); 7.1(wide) takes a PCE
        // unless allowed.
        if (!needs_pce and chcfg == 7 and !options.allow_71wide) needs_pce = true;
        var pce: ?*const pce_tab.Config = null;
        if (needs_pce) {
            pce = for (&pce_tab.configs) |*c| {
                if (c.mask == layout) break c;
            } else return error.UnsupportedFormat; // "Unsupported channel layout"
            chcfg = 0;
        }
        var opt = options;
        // Profile.
        var profile = if (opt.profile == profile_unknown) profile_aac_low else opt.profile;
        if (profile != profile_aac_low and profile != profile_mpeg2_aac_low) return error.InvalidOption; // "Profile not supported!"
        if (profile == profile_mpeg2_aac_low) {
            profile = profile_aac_low;
            opt.pns = 0;
        }
        const channels: u8 = @popCount(layout);
        const chan_map: []const u8 = if (pce) |c| &c.config_map else &chan_configs[chcfg - 1];
        const reorder_map: []const u8 = if (pce) |c| &c.reorder_map else &chan_maps[chcfg - 1];
        // check_height_ext: a top channel (AV_CHAN_TOP_FRONT_LEFT to
        // AV_CHAN_TOP_BACK_RIGHT, bits 12 to 17).
        const needs_height_ext = pce != null and layout & 0x3f000 != 0;
        var bit_rate = opt.bit_rate;
        if (bit_rate == 0) {
            for (1..@as(usize, chan_map[0]) + 1) |i| {
                bit_rate += switch (chan_map[i]) {
                    ElementType.cpe => 128000,
                    ElementType.lfe => 16000,
                    else => 69000,
                };
            }
        }
        // The bit rate limit: FFMIN in double, then int64.
        const limit: f64 = @as(f64, @floatFromInt(@as(i32, 6144) * channels)) / 1024.0 * @as(f64, @floatFromInt(sample_rate));
        const br_f: f64 = @floatFromInt(bit_rate);
        bit_rate = @intFromFloat(@trunc(if (limit > br_f) br_f else limit));
        // M/S introduces artifacts with many channels (temporary in FFmpeg).
        if (channels > 3) opt.mid_side = 0;
        const lambda: f32 = if (opt.global_quality > 0) @floatFromInt(opt.global_quality) else 120;

        // The coding bandwidth, fixed at init.
        var bandwidth: i32 = undefined;
        if (opt.cutoff > 0) {
            bandwidth = opt.cutoff;
        } else {
            var frame_br: i32 = undefined;
            if (opt.qscale) {
                if (opt.coder == .nmr) {
                    // The expected per-channel rate of the quality ladder.
                    const gq: f32 = @floatFromInt(opt.global_quality);
                    const q: f32 = if (opt.global_quality > 0) gq / 118.0 else 1.0;
                    frame_br = cconv.cvttsd2si32(66000.0 * libm.powf(q, 0.29));
                } else {
                    frame_br = cconv.cvttsd2si32(@as(f32, @floatFromInt(bit_rate)) / 2.0 * (lambda / 120.0) * 1.5);
                }
            } else {
                frame_br = @intCast(@divTrunc(bit_rate, channels));
            }
            if (opt.coder == .nmr and frame_br >= 24000) {
                // The NMR coder's bandwidth table, interpolated.
                const rates = [_]i32{ 24000, 32000, 48000, 64000, 96000, 192000 };
                const bws = [_]i32{ 14000, 14000, 15000, 16000, 19500, 22000 };
                var i: usize = 0;
                while (i < rates.len - 2 and frame_br > rates[i + 1]) i += 1;
                const span: i64 = bws[i + 1] - bws[i];
                // C converts the int64 quotient to int.
                const add: i32 = @truncate(@divTrunc(span * (frame_br - rates[i]), rates[i + 1] - rates[i]));
                bandwidth = bws[i] + add;
                bandwidth = @min(@min(bandwidth, 22000), @as(i32, @intCast(sample_rate / 2)));
            } else {
                if (opt.pns != 0 or opt.intensity_stereo != 0) frame_br = cconv.cvttsd2si32(@as(f32, @floatFromInt(frame_br)) * 1.15);
                bandwidth = @max(3000, cutoffFromBitrate(frame_br, 1, @intCast(sample_rate)));
            }
            bandwidth = @min(@max(bandwidth, 8000), @as(i32, @intCast(sample_rate / 2)));
        }

        const e = try gpa.create(Encoder);
        errdefer gpa.destroy(e);
        const cpe = try gpa.alloc(Cpe, chan_map[0]);
        errdefer gpa.free(cpe);
        for (cpe) |*c| c.* = .{};
        const nmr_state: ?*nmr_coder.State = if (opt.coder == .nmr) try gpa.create(nmr_coder.State) else null;
        errdefer if (nmr_state) |n| gpa.destroy(n);
        if (nmr_state) |n| n.* = .{};
        var grouping: [max_channels]u8 = undefined;
        for (0..chan_map[0]) |i| grouping[i] = @intFromBool(chan_map[i + 1] == ElementType.cpe);
        var psy = aacpsy.Psy.init(gpa, .{
            .sample_rate = sample_rate,
            .channels = channels,
            .bit_rate = bit_rate,
            .qscale = opt.qscale,
            .global_quality = opt.global_quality,
            .cutoff = bandwidth,
            // The quality-target modes of the NMR coder own the rate.
            .unbounded_pe = (opt.qscale or opt.rc == 1) and opt.coder == .nmr,
            .band_sizes = .{ enc_tab.swb_size_1024[sr_index], enc_tab.swb_size_128[sr_index] },
            .groups = grouping[0..chan_map[0]],
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // The bandwidth is at least 8000 Hz or a positive cutoff.
            error.InvalidConfig => unreachable,
        };
        errdefer psy.deinit();
        var mdct1024 = tx.Mdct.init(gpa, 1024, false, 32768.0) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnsupportedLength => unreachable,
        };
        errdefer mdct1024.deinit();
        const mdct128 = tx.Mdct.init(gpa, 128, false, 32768.0) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnsupportedLength => unreachable,
        };
        e.* = .{
            .gpa = gpa,
            .opt = opt,
            .bit_rate = bit_rate,
            .sample_rate = sample_rate,
            .samplerate_index = sr_index,
            .channels = channels,
            .profile = profile,
            .chcfg = chcfg,
            .reorder_map = reorder_map,
            .chan_map = chan_map,
            .pce = pce,
            .needs_height_ext = needs_height_ext,
            .bandwidth = bandwidth,
            .cpe = cpe,
            .psy = psy,
            .mdct1024 = mdct1024,
            .mdct128 = mdct128,
            .lambda = lambda,
            .esc_pow43 = undefined,
            .nmr = nmr_state,
        };
        // ff_aac_coder_init_tables.
        for (&e.esc_pow43, 0..) |*p, c| {
            const cf: f32 = @floatFromInt(c);
            p.* = cf * libm.cbrtf(cf);
        }
        e.putAudioSpecificConfig();
        return e;
    }

    pub fn deinit(e: *Encoder) void {
        e.mdct1024.deinit();
        e.mdct128.deinit();
        e.psy.deinit();
        if (e.nmr) |n| e.gpa.destroy(n);
        e.gpa.free(e.cpe);
        e.gpa.destroy(e);
    }

    /// The psy model's bands of channel `ch`.
    pub fn psyBands(e: *Encoder, ch: usize) *const [128]PsyBand {
        return e.psy.bands(ch);
    }

    /// ff_quantize_band_cost_cache_init.
    pub fn costCacheInit(e: *Encoder) void {
        e.cost_cache_generation +%= 1;
        if (e.cost_cache_generation == 0) {
            e.cost_cache = @splat(@splat(.{}));
            e.cost_cache_generation = 1;
        }
    }

    /// The AudioSpecificConfig.
    pub fn extradata(e: *const Encoder) []const u8 {
        return e.extradata_buf[0..e.extradata_len];
    }

    /// put_audio_specific_config: the profile, the rate's index, the
    /// channel configuration (or the PCE) and SBR explicitly absent.
    fn putAudioSpecificConfig(e: *Encoder) void {
        var w: bits.BitWriter = .init(&e.extradata_buf);
        w.bits(5, @intCast(e.profile + 1));
        w.bits(4, e.samplerate_index);
        w.bits(4, e.chcfg);
        w.bits(1, 0); // frame length: 1024 samples
        w.bits(1, 0); // no core coder
        w.bits(1, 0); // no extension
        if (e.pce) |c| e.putPce(&w, c);
        w.bits(11, 0x2b7); // sync extension
        w.bits(5, 5); // AOT_SBR
        w.bits(1, 0);
        w.flush();
        e.extradata_len = w.pos;
    }

    /// put_pce, as FFmpeg writes it with AV_CODEC_FLAG_BITEXACT: the
    /// comment field holds "Lavc" (or the height extension).
    fn putPce(e: *const Encoder, w: *bits.BitWriter, c: *const pce_tab.Config) void {
        w.bits(4, 0); // element instance tag
        w.bits(2, @intCast(e.profile));
        w.bits(4, e.samplerate_index);
        w.bits(4, c.num_ele[0]); // front
        w.bits(4, c.num_ele[1]); // side
        w.bits(4, c.num_ele[2]); // back
        w.bits(2, c.num_ele[3]); // LFE
        w.bits(3, 0); // associated data
        w.bits(4, 0); // coupling channels
        w.bits(1, 0); // stereo mixdown
        w.bits(1, 0); // mono mixdown
        w.bits(1, 0); // matrix mixdown
        for (0..4) |i| {
            for (0..c.num_ele[i]) |j| {
                if (i < 3) w.bits(1, c.pairing[i][j]);
                w.bits(4, c.index[i][j]);
            }
        }
        alignBits(w);
        if (e.needs_height_ext) {
            var buf: [16]u8 = @splat(0);
            const nbits: usize = 8 + @as(usize, c.num_ele[0]) * 2 + @as(usize, c.num_ele[1]) * 2 + @as(usize, c.num_ele[2]) * 2;
            const nbytes = (nbits + 7) / 8;
            var hw: bits.BitWriter = .init(buf[0..nbytes]);
            hw.bits(8, 0xAC);
            for (0..3) |i| {
                for (0..c.num_ele[i]) |j| hw.bits(2, c.height[i][j]);
            }
            hw.flush();
            w.bits(8, nbytes + 1);
            // ff_copy_bits: the bits, MSB first.
            for (buf[0 .. nbits / 8]) |b| w.bits(8, b);
            if (nbits % 8 != 0) w.bits(@intCast(nbits % 8), buf[nbits / 8] >> @intCast(8 - nbits % 8));
            alignBits(w);
            w.bits(8, crc8Atm(buf[0..nbytes]));
        } else {
            const aux = "Lavc";
            w.bits(8, aux.len);
            for (aux) |ch| w.bits(8, ch);
        }
    }

    /// copy_input_samples: the next block moves to the current one, the
    /// frame's samples (in AAC order) become the next block, zero padded.
    fn copyInputSamples(e: *Encoder, frame: ?[]const []const f32, count: usize) void {
        const end = 2048 + (if (frame != null) count else 0);
        for (0..e.channels) |ch| {
            const s = &e.samples[ch];
            @memcpy(s[1024..2048], s[2048..3072]);
            if (frame) |planes| @memcpy(s[2048..][0..count], planes[e.reorder_map[ch]][0..count]);
            @memset(s[end..3072], 0);
        }
    }

    /// apply_window_and_mdct.
    fn applyWindowAndMdct(e: *Encoder, sce: *Sce, audio: *[3 * 1024]f32) void {
        const out = &sce.ret_buf;
        const kb = sce.ics.use_kb_window;
        switch (sce.ics.window_sequence[0]) {
            .only_long => {
                const lwindow: []const f32 = if (kb[0] != 0) &aac_tab.kbd_long_1024 else &aac_tab.sine_1024;
                const pwindow: []const f32 = if (kb[1] != 0) &aac_tab.kbd_long_1024 else &aac_tab.sine_1024;
                float_dsp.fmul(out[0..1024], audio[0..1024], lwindow, 1024);
                float_dsp.fmulReverse(out[1024..2048], audio[1024..2048], pwindow, 1024);
            },
            .long_start => {
                const lwindow: []const f32 = if (kb[1] != 0) &aac_tab.kbd_long_1024 else &aac_tab.sine_1024;
                const swindow: []const f32 = if (kb[0] != 0) &aac_tab.kbd_short_128 else &aac_tab.sine_128;
                float_dsp.fmul(out[0..1024], audio[0..1024], lwindow, 1024);
                @memcpy(out[1024..][0..448], audio[1024..][0..448]);
                float_dsp.fmulReverse(out[1024 + 448 ..][0..128], audio[1024 + 448 ..][0..128], swindow, 128);
                @memset(out[1024 + 576 ..][0..448], 0);
            },
            .long_stop => {
                const lwindow: []const f32 = if (kb[0] != 0) &aac_tab.kbd_long_1024 else &aac_tab.sine_1024;
                const swindow: []const f32 = if (kb[1] != 0) &aac_tab.kbd_short_128 else &aac_tab.sine_128;
                @memset(out[0..448], 0);
                float_dsp.fmul(out[448..][0..128], audio[448..][0..128], swindow, 128);
                @memcpy(out[576..][0..448], audio[576..][0..448]);
                float_dsp.fmulReverse(out[1024..2048], audio[1024..2048], lwindow, 1024);
            },
            .eight_short => {
                const swindow: []const f32 = if (kb[0] != 0) &aac_tab.kbd_short_128 else &aac_tab.sine_128;
                const pwindow: []const f32 = if (kb[1] != 0) &aac_tab.kbd_short_128 else &aac_tab.sine_128;
                var in: usize = 448;
                var o: usize = 0;
                for (0..8) |w| {
                    float_dsp.fmul(out[o..][0..128], audio[in..][0..128], if (w != 0) pwindow else swindow, 128);
                    o += 128;
                    in += 128;
                    float_dsp.fmulReverse(out[o..][0..128], audio[in..][0..128], swindow, 128);
                    o += 128;
                }
            },
        }
        if (sce.ics.window_sequence[0] != .eight_short) {
            e.mdct1024.run(&sce.coeffs, out);
        } else {
            var i: usize = 0;
            while (i < 1024) : (i += 128) e.mdct128.run(sce.coeffs[i..][0..128], out[i * 2 ..][0..256]);
        }
        @memcpy(audio[0..1024], audio[1024..2048]);
        sce.pcoeffs = sce.coeffs;
    }

    /// One frame of planar float samples (`samples[ch]`, FFmpeg's layout
    /// order, each `count` long, at most 1024), or null to flush; the
    /// packet goes to `out` (at least `packetCapacity` bytes). Null when
    /// there is no packet (the first frame, or a flush with nothing left),
    /// as aac_encode_frame with the frame queue and encode.c's frame count.
    pub fn encodeFrame(e: *Encoder, samples: ?[]const []const f32, count: usize, out: []u8) FrameError!?[]u8 {
        std.debug.assert(out.len >= e.packetCapacity());
        var frame_num: i64 = undefined;
        if (samples) |planes| {
            if (planes.len != e.channels or count > frame_samples) return error.InvalidFrame;
            for (planes) |p| if (p.len < count) return error.InvalidFrame;
            e.remaining_samples += @intCast(count);
            e.got_frame = true;
            frame_num = e.frame_num;
            e.frame_num += 1;
        } else {
            frame_num = e.frame_num;
            if (!e.draining) {
                e.draining = true;
                e.frame_num += 1;
            }
            if (e.remaining_samples == 0 or !e.got_frame) return null;
        }
        e.copyInputSamples(samples, count);
        if (frame_num == 0) return null;
        const packet = try e.encodeOne(samples != null, frame_num, out);
        e.remaining_samples -= @min(e.remaining_samples, frame_samples);
        return packet;
    }

    /// The largest packet: 8192 bytes a channel (ff_alloc_packet's size).
    pub fn packetCapacity(e: *const Encoder) usize {
        return 8192 * @as(usize, e.channels);
    }

    fn encodeOne(e: *Encoder, have_frame: bool, frame_num: i64, out: []u8) FrameError![]u8 {
        var windows: [max_channels]aacpsy.WindowInfo = undefined;
        var start_ch: usize = 0;
        for (0..e.chan_map[0]) |i| {
            const wi = windows[start_ch..];
            const tag = e.chan_map[i + 1];
            const chans: usize = if (tag == ElementType.cpe) 2 else 1;
            const cpe = &e.cpe[i];
            var wi_paired = false;
            // A pair's windows are decided together, so their block
            // switching never diverges.
            if (chans == 2 and tag != ElementType.lfe and have_frame) {
                // The model's arguments are valid by construction.
                const pair = e.psy.windowPair(lookahead(&e.samples[start_ch]), lookahead(&e.samples[start_ch + 1]), start_ch, start_ch + 1, cpe.ch[0].ics.window_sequence[0], cpe.ch[1].ics.window_sequence[0]) catch unreachable;
                wi[0] = pair[0];
                wi[1] = pair[1];
                wi_paired = true;
            }
            for (0..chans) |ch| {
                const sce = &cpe.ch[ch];
                const ics = &sce.ics;
                e.cur_channel = start_ch + ch;
                const overlap = &e.samples[e.cur_channel];
                if (tag == ElementType.lfe) {
                    wi[ch] = .{
                        .window_type = .{ .only_long, .only_long, .only_long },
                        .window_shape = 0,
                        .num_windows = 1,
                        .grouping = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
                        .clipping = @splat(0),
                    };
                    // An LFE codes its lowest 12 coefficients (8 at 16 kHz
                    // and below).
                    ics.num_swb = if (e.samplerate_index >= 8) 1 else 3;
                } else if (!wi_paired) {
                    wi[ch] = e.psy.window(if (have_frame) lookahead(overlap) else null, e.cur_channel, ics.window_sequence[0]) catch unreachable;
                }
                ics.window_sequence[1] = ics.window_sequence[0];
                ics.window_sequence[0] = wi[ch].window_type[0];
                ics.use_kb_window[1] = ics.use_kb_window[0];
                ics.use_kb_window[0] = wi[ch].window_shape;
                ics.num_windows = wi[ch].num_windows;
                const short = ics.num_windows == 8;
                ics.swb_sizes = if (short) enc_tab.swb_size_128[e.samplerate_index] else enc_tab.swb_size_1024[e.samplerate_index];
                ics.num_swb = if (tag == ElementType.lfe) ics.num_swb else (if (short) aac_tab.num_swb_128[e.samplerate_index] else aac_tab.num_swb_1024[e.samplerate_index]);
                ics.max_sfb = @min(ics.max_sfb, ics.num_swb);
                ics.swb_offset = if (wi[ch].window_type[0] == .eight_short) aac_tab.swb_offset_128[e.samplerate_index] else aac_tab.swb_offset_1024[e.samplerate_index];
                ics.tns_max_bands = if (wi[ch].window_type[0] == .eight_short) aac_tab.tns_max_bands_128[e.samplerate_index] else aac_tab.tns_max_bands_1024[e.samplerate_index];
                for (0..ics.num_windows) |w| ics.group_len[w] = wi[ch].grouping[w];

                // The input's peaks, and the clipping risk.
                var cav: f32 = 0;
                const wlen = 2048 / @as(usize, ics.num_windows);
                for (0..ics.num_windows) |w| {
                    var max: f32 = 0;
                    for (overlap[w * 128 ..][0..wlen]) |x| {
                        // FFMAX(max, fabsf(x)).
                        const a = @abs(x);
                        max = if (max > a) max else a;
                    }
                    wi[ch].clipping[w] = max;
                }
                // The NMR coder keeps levels exact: float decoders do not
                // clip.
                if (e.opt.coder == .nmr) {
                    for (0..ics.num_windows) |w| wi[ch].clipping[w] = 0;
                }
                for (0..ics.num_windows) |w| {
                    if (wi[ch].clipping[w] > clip_avoidance_factor) {
                        ics.window_clipping[w] = 1;
                        cav = if (cav > wi[ch].clipping[w]) cav else wi[ch].clipping[w];
                    } else {
                        ics.window_clipping[w] = 0;
                    }
                }
                ics.clip_avoidance_factor = if (cav > clip_avoidance_factor) clip_avoidance_factor / cav else 1.0;

                e.applyWindowAndMdct(sce, overlap);
                for (sce.coeffs) |c| {
                    // Headroom for the energies.
                    if (!(@abs(@as(f64, c)) < 1e16)) return error.InvalidInput;
                }
                avoidClipping(sce);
            }
            start_ch += chans;
        }

        var w: bits.BitWriter = undefined;
        var its: i32 = 0;
        var frame_bits: i32 = 0;
        var is_mode = false;
        var ms_mode = false;
        var tns_mode = false;
        var tag: u8 = 0;
        while (true) {
            w = .init(out[0..e.packetCapacity()]);
            start_ch = 0;
            var target_bits: i32 = 0;
            var chan_el_counter: [4]u8 = @splat(0);
            for (0..e.chan_map[0]) |i| {
                const wi = windows[start_ch..];
                tag = e.chan_map[i + 1];
                const chans: usize = if (tag == ElementType.cpe) 2 else 1;
                const cpe = &e.cpe[i];
                cpe.common_window = false;
                cpe.is_mask = @splat(0);
                cpe.ms_mask = @splat(0);
                w.bits(3, tag);
                w.bits(4, chan_el_counter[tag]);
                chan_el_counter[tag] += 1;
                var coeffs: [2]*const [1024]f32 = undefined;
                for (0..chans) |ch| {
                    const sce = &cpe.ch[ch];
                    coeffs[ch] = &sce.coeffs;
                    sce.tns = .{};
                    for (&sce.band_type) |*b| {
                        if (b.* > BandType.reserved) b.* = 0;
                    }
                }
                e.psy.bitres.alloc = -1;
                e.psy.bitres.bits = @divTrunc(e.last_frame_pb_count, e.channels);
                // A group's channels, from its first (valid by construction).
                e.psy.analyze(start_ch, coeffs[0..chans], wi[0..chans], frame_num) catch unreachable;
                if (e.psy.bitres.alloc > 0) {
                    // psy's unscaled allocation, scaled by lambda here.
                    const gq: f32 = @floatFromInt(if (e.opt.global_quality != 0) e.opt.global_quality else 120);
                    target_bits = cconv.cvttsd2si32(@as(f32, @floatFromInt(target_bits)) + @as(f32, @floatFromInt(e.psy.bitres.alloc)) * (e.lambda / gq));
                    e.psy.bitres.alloc = @divTrunc(e.psy.bitres.alloc, @as(i32, @intCast(chans)));
                }
                e.cur_type = tag;
                if (chans > 1 and wi[0].window_type[0] == wi[1].window_type[0] and wi[0].window_shape == wi[1].window_shape) {
                    cpe.common_window = true;
                    for (0..wi[0].num_windows) |win| {
                        if (wi[0].grouping[win] != wi[1].grouping[win]) {
                            cpe.common_window = false;
                            break;
                        }
                    }
                }
                const use_tns = e.opt.tns != 0;
                // The NMR coder controls its own rate and never quantizes
                // again, so TNS runs before it.
                const nmr = e.opt.coder == .nmr;
                if (nmr and use_tns) {
                    for (0..chans) |ch| {
                        const sce = &cpe.ch[ch];
                        e.cur_channel = start_ch + ch;
                        // Mono: PNS marked first, so TNS's band range sees
                        // it.
                        if (chans == 1 and e.opt.pns != 0) coder.markPns(e, sce);
                        tns_mod.searchForTns(e, sce);
                        tns_mod.applyTns(sce);
                        if (sce.tns.present) tns_mode = true;
                    }
                }
                // The NMR coder's stereo PNS: only where both channels'
                // L/R bands are noise-like.
                if (chans == 2 and cpe.common_window and nmr and e.opt.pns != 0) {
                    e.cur_channel = start_ch;
                    coder.markPns(e, &cpe.ch[0]);
                    e.cur_channel = start_ch + 1;
                    coder.markPns(e, &cpe.ch[1]);
                    for (&cpe.ch[0].can_pns, &cpe.ch[1].can_pns) |*p0, *p1| {
                        if (p0.* == 0 or p1.* == 0) {
                            p0.* = 0;
                            p1.* = 0;
                        }
                    }
                }
                // The NMR coder decides I/S and M/S before quantizing.
                if (chans == 2 and cpe.common_window and nmr and (e.opt.mid_side != 0 or e.opt.intensity_stereo != 0)) {
                    e.cur_channel = start_ch;
                    nmr_coder.decideStereo(e, cpe);
                }
                // It pools a CPE's bit budget.
                if (e.nmr) |n| n.pair = chans == 2;
                for (0..chans) |ch| {
                    e.cur_channel = start_ch + ch;
                    if (e.opt.pns != 0 and !nmr) coder.markPns(e, &cpe.ch[ch]);
                    switch (e.opt.coder) {
                        .twoloop => coder.searchForQuantizersTwoloop(e, &cpe.ch[ch], e.lambda),
                        .fast => coder.searchForQuantizersFast(e, &cpe.ch[ch], e.lambda),
                        .nmr => nmr_coder.searchForQuantizers(e, &cpe.ch[ch], e.lambda, frame_num),
                    }
                }
                // TNS (other coders) and PNS (decided in NMR's trellis).
                if (!nmr) {
                    for (0..chans) |ch| {
                        const sce = &cpe.ch[ch];
                        e.cur_channel = start_ch + ch;
                        if (use_tns) {
                            tns_mod.searchForTns(e, sce);
                            tns_mod.applyTns(sce);
                            if (sce.tns.present) tns_mode = true;
                        }
                        if (e.opt.pns != 0) coder.searchForPns(e, sce);
                    }
                }
                e.cur_channel = start_ch;
                if (e.opt.intensity_stereo != 0) {
                    // NMR: decided before the search.
                    if (chans == 2 and !nmr) {
                        coder.searchForIs(e, cpe);
                        applyIntensityStereo(cpe);
                    }
                    if (cpe.is_mode != 0) is_mode = true;
                }
                if (e.opt.mid_side != 0 and chans == 2 and !nmr) {
                    if (e.opt.mid_side == -1) {
                        coder.searchForMs(e, cpe);
                    } else if (cpe.common_window) {
                        cpe.ms_mask = @splat(1);
                    }
                    applyMidSideStereo(cpe);
                }
                adjustFrameInformation(cpe, chans);
                if (chans == 2) {
                    w.bits(1, @intFromBool(cpe.common_window));
                    if (cpe.common_window) {
                        putIcsInfo(&w, &cpe.ch[0].ics);
                        encodeMsInfo(&w, cpe);
                        if (cpe.ms_mode != 0) ms_mode = true;
                    }
                }
                for (0..chans) |ch| {
                    e.cur_channel = start_ch + ch;
                    e.encodeIndividualChannel(&w, &cpe.ch[ch], cpe.common_window);
                }
                start_ch += chans;
            }

            const max_frame = 6144 * @as(i32, e.channels) - 3;
            if (e.opt.qscale) {
                // A constant Q-scale keeps lambda unless the frame does not
                // fit the decoder's buffer: retry coarser.
                frame_bits = @intCast(w.count());
                if (frame_bits < max_frame or its >= 16) break;
                e.lambda *= @min(0.9, (6144.0 * @as(f32, @floatFromInt(e.channels)) - 3) / @as(f32, @floatFromInt(frame_bits)));
                for (0..e.chan_map[0]) |i| {
                    const n: usize = if (e.chan_map[i + 1] == ElementType.cpe) 2 else 1;
                    for (0..n) |ch| e.cpe[i].ch[ch].coeffs = e.cpe[i].ch[ch].pcoeffs;
                }
                its += 1;
                continue;
            }
            frame_bits = @intCast(w.count());
            // The NMR coder controls its own rate (with a nonzero
            // bit_rate_tolerance, libavcodec's default): only a hard
            // overflow goes through the lambda loop.
            if (e.opt.coder == .nmr and frame_bits < max_frame) break;
            // Between the nominal bit rate and psy's reservoir target,
            // drifting towards the nominal rate.
            var rate_bits: i32 = @intCast(@divTrunc(e.bit_rate * 1024, e.sample_rate));
            rate_bits = @min(rate_bits, max_frame);
            var too_many_bits = @max(target_bits, rate_bits);
            too_many_bits = @min(too_many_bits, max_frame);
            var too_few_bits = @min(@max(rate_bits - @divTrunc(rate_bits, 4), target_bits), too_many_bits);
            // ABR: strict, but only for increasing.
            too_few_bits = too_few_bits - @divTrunc(too_few_bits, 8);
            too_many_bits = too_many_bits + @divTrunc(too_many_bits, 2);
            if (its == 0 or (its < 5 and (frame_bits < too_few_bits or frame_bits > too_many_bits)) or frame_bits >= max_frame) {
                var ratio = @as(f32, @floatFromInt(rate_bits)) / @as(f32, @floatFromInt(frame_bits));
                if (frame_bits >= too_few_bits and frame_bits <= too_many_bits) {
                    // Steady-state Q-scale tracking: slowly.
                    ratio = @sqrt(@sqrt(ratio));
                    ratio = coder.clipf(ratio, 0.9, 1.1);
                } else {
                    // Not so fast though.
                    ratio = @sqrt(ratio);
                }
                e.lambda = coder.clipf(e.lambda * ratio, std.math.floatEps(f32), 65536.0);
                if (ratio > 0.9 and ratio < 1.1) break;
                if (is_mode or ms_mode or tns_mode) {
                    for (0..e.chan_map[0]) |i| {
                        // FFmpeg's loop takes every element's channels from
                        // the last element's tag.
                        const n: usize = if (tag == ElementType.cpe) 2 else 1;
                        for (0..n) |ch| e.cpe[i].ch[ch].coeffs = e.cpe[i].ch[ch].pcoeffs;
                    }
                }
                its += 1;
            } else {
                break;
            }
        }
        if (e.opt.qscale) e.lambda = if (e.opt.global_quality > 0) @floatFromInt(e.opt.global_quality) else 120;

        w.bits(3, ElementType.end);
        w.flush();
        e.last_frame_pb_count = @intCast(w.count());
        // The NMR coder's accounting: the bits the frame took beyond what
        // its trellis counted.
        if (e.nmr) |n| {
            var counted: i32 = 0;
            for (n.counted[0..e.channels]) |c| counted += c;
            if (counted > 0) {
                const side = @as(f32, @floatFromInt(e.last_frame_pb_count)) - @as(f32, @floatFromInt(counted));
                if (n.side_inited) {
                    n.side_ema += 0.125 * (side - n.side_ema);
                } else {
                    n.side_ema = side;
                    n.side_inited = true;
                }
            }
        }
        return w.written();
    }

    /// encode_individual_channel.
    fn encodeIndividualChannel(e: *Encoder, w: *bits.BitWriter, sce: *Sce, common_window: bool) void {
        w.bits(8, @intCast(sce.sf_idx[0] & 0xff));
        if (!common_window) putIcsInfo(w, &sce.ics);
        // encode_band_info.
        coder.setSpecialBandScalefactors(sce);
        var win: usize = 0;
        while (win < sce.ics.num_windows) : (win += sce.ics.group_len[win]) {
            coder.codebookTrellisRate(e, w, sce, win, sce.ics.group_len[win]);
        }
        encodeScaleFactors(w, sce);
        w.bits(1, 0); // no pulses
        w.bits(1, @intFromBool(sce.tns.present));
        tns_mod.encodeTnsInfo(w, sce);
        w.bits(1, 0); // no gain control (ssr)
        // encode_spectral_coeffs.
        win = 0;
        while (win < sce.ics.num_windows) : (win += sce.ics.group_len[win]) {
            var start: usize = 0;
            for (0..sce.ics.max_sfb) |i| {
                if (sce.zeroes[win * 16 + i] != 0) {
                    start += sce.ics.swb_sizes[i];
                    continue;
                }
                for (win..win + sce.ics.group_len[win]) |w2| {
                    coder.quantizeAndEncodeBand(e, w, sce.coeffs[start + w2 * 128 ..], null, sce.ics.swb_sizes[i], sce.sf_idx[win * 16 + i], sce.band_type[win * 16 + i], e.lambda, sce.ics.window_clipping[win] != 0);
                }
                start += sce.ics.swb_sizes[i];
            }
        }
    }
};

/// align_put_bits: zeros to the next byte.
fn alignBits(w: *bits.BitWriter) void {
    const rem = w.count() % 8;
    if (rem != 0) w.bits(@intCast(8 - rem), 0);
}

/// av_crc with AV_CRC_8_ATM from 0xFF: polynomial 0x07, MSB first.
fn crc8Atm(data: []const u8) u8 {
    var crc: u8 = 0xFF;
    for (data) |b| {
        crc ^= b;
        for (0..8) |_| crc = if (crc & 0x80 != 0) (crc << 1) ^ 0x07 else crc << 1;
    }
    return crc;
}

/// The psy model's lookahead in a channel's buffer: `la = samples2 + 448
/// + 64`, from the current block at 1024.
fn lookahead(buf: *const [3 * 1024]f32) *const [aacpsy.lookahead_len]f32 {
    return buf[1536..][0..aacpsy.lookahead_len];
}

/// avoid_clipping: a near-clipping frame's coefficients scaled down.
fn avoidClipping(sce: *Sce) void {
    if (!(sce.ics.clip_avoidance_factor < 1.0)) return;
    for (0..sce.ics.num_windows) |w| {
        var start: usize = 0;
        for (0..sce.ics.max_sfb) |i| {
            for (sce.coeffs[start + w * 128 ..][0..sce.ics.swb_sizes[i]]) |*c| c.* *= sce.ics.clip_avoidance_factor;
            start += sce.ics.swb_sizes[i];
        }
    }
}

/// put_ics_info.
fn putIcsInfo(w: *bits.BitWriter, info: *const Ics) void {
    w.bits(1, 0); // ics_reserved_bit
    w.bits(2, @backingInt(info.window_sequence[0]));
    w.bits(1, info.use_kb_window[0]);
    if (info.window_sequence[0] != .eight_short) {
        w.bits(6, info.max_sfb);
        w.bits(1, 0); // no predictor
    } else {
        w.bits(4, info.max_sfb);
        for (1..8) |i| w.bits(1, @intFromBool(info.group_len[i] == 0));
    }
}

/// encode_ms_info.
fn encodeMsInfo(w: *bits.BitWriter, cpe: *const Cpe) void {
    w.bits(2, @intCast(cpe.ms_mode));
    if (cpe.ms_mode == 1) {
        var win: usize = 0;
        while (win < cpe.ch[0].ics.num_windows) : (win += cpe.ch[0].ics.group_len[win]) {
            for (0..cpe.ch[0].ics.max_sfb) |i| w.bits(1, cpe.ms_mask[win * 16 + i]);
        }
    }
}

/// adjust_frame_information: max_sfb from the zero bands, a group's band
/// zero only when all its windows are, and the M/S mode.
fn adjustFrameInformation(cpe: *Cpe, chans: usize) void {
    for (0..chans) |ch| {
        const sce = &cpe.ch[ch];
        const ics = &sce.ics;
        var maxsfb: u8 = 0;
        var w: usize = 0;
        while (w < ics.num_windows) : (w += ics.group_len[w]) {
            var cmaxsfb: u8 = ics.num_swb;
            while (cmaxsfb > 0 and sce.zeroes[w * 16 + cmaxsfb - 1] != 0) cmaxsfb -= 1;
            maxsfb = @max(maxsfb, cmaxsfb);
        }
        ics.max_sfb = maxsfb;
        w = 0;
        while (w < ics.num_windows) : (w += ics.group_len[w]) {
            for (0..ics.max_sfb) |g| {
                var all_zero: u8 = 1;
                for (w..w + ics.group_len[w]) |w2| {
                    if (sce.zeroes[w2 * 16 + g] == 0) {
                        all_zero = 0;
                        break;
                    }
                }
                sce.zeroes[w * 16 + g] = all_zero;
            }
        }
    }
    if (chans > 1 and cpe.common_window) {
        const ics0 = &cpe.ch[0].ics;
        const ics1 = &cpe.ch[1].ics;
        var msc: i32 = 0;
        ics0.max_sfb = @max(ics0.max_sfb, ics1.max_sfb);
        ics1.max_sfb = ics0.max_sfb;
        var w: usize = 0;
        while (w < @as(usize, ics0.num_windows) * 16) : (w += 16) {
            for (0..ics0.max_sfb) |i| {
                if (cpe.ms_mask[w + i] != 0) msc += 1;
            }
        }
        if (msc == 0 or ics0.max_sfb == 0) {
            cpe.ms_mode = 0;
        } else {
            cpe.ms_mode = if (msc < @as(i32, ics0.max_sfb) * ics0.num_windows) 1 else 2;
        }
    }
}

/// apply_intensity_stereo.
fn applyIntensityStereo(cpe: *Cpe) void {
    const ics = &cpe.ch[0].ics;
    if (!cpe.common_window) return;
    var w: usize = 0;
    while (w < ics.num_windows) : (w += ics.group_len[w]) {
        for (0..ics.group_len[w]) |w2| {
            var start = (w + w2) * 128;
            for (0..ics.num_swb) |g| {
                const b = w * 16 + g;
                var p: i32 = -1 + 2 * (@as(i32, cpe.ch[1].band_type[b]) - 14);
                const scale = cpe.ch[0].is_ener[b];
                if (cpe.is_mask[b] == 0) {
                    start += ics.swb_sizes[g];
                    continue;
                }
                if (cpe.ms_mask[b] != 0) p *= -1;
                const fp: f32 = @floatFromInt(p);
                for (0..ics.swb_sizes[g]) |i| {
                    const sum = (cpe.ch[0].coeffs[start + i] + fp * cpe.ch[1].coeffs[start + i]) * scale;
                    cpe.ch[0].coeffs[start + i] = sum;
                    cpe.ch[1].coeffs[start + i] = 0;
                }
                start += ics.swb_sizes[g];
            }
        }
    }
}

/// apply_mid_side_stereo: not where PNS or I/S use the band.
fn applyMidSideStereo(cpe: *Cpe) void {
    const ics = &cpe.ch[0].ics;
    if (!cpe.common_window) return;
    var w: usize = 0;
    while (w < ics.num_windows) : (w += ics.group_len[w]) {
        for (0..ics.group_len[w]) |w2| {
            var start = (w + w2) * 128;
            for (0..ics.num_swb) |g| {
                const b = w * 16 + g;
                if (cpe.ms_mask[b] == 0 or cpe.is_mask[b] != 0 or cpe.ch[0].band_type[b] >= BandType.noise or cpe.ch[1].band_type[b] >= BandType.noise) {
                    start += ics.swb_sizes[g];
                    continue;
                }
                for (0..ics.swb_sizes[g]) |i| {
                    const l = (cpe.ch[0].coeffs[start + i] + cpe.ch[1].coeffs[start + i]) * 0.5;
                    const r = l - cpe.ch[1].coeffs[start + i];
                    cpe.ch[0].coeffs[start + i] = l;
                    cpe.ch[1].coeffs[start + i] = r;
                }
                start += ics.swb_sizes[g];
            }
        }
    }
}

/// encode_scale_factors: differences per chain (spectral, PNS with its
/// preamble, I/S).
fn encodeScaleFactors(w: *bits.BitWriter, sce: *const Sce) void {
    var off_sf = sce.sf_idx[0];
    var off_pns = sce.sf_idx[0] - noise_offset;
    var off_is: i32 = 0;
    var noise_flag: i32 = 1;
    var win: usize = 0;
    while (win < sce.ics.num_windows) : (win += sce.ics.group_len[win]) {
        for (0..sce.ics.max_sfb) |i| {
            const b = win * 16 + i;
            if (sce.zeroes[b] != 0) continue;
            var diff: i32 = undefined;
            if (sce.band_type[b] == BandType.noise) {
                diff = sce.sf_idx[b] - off_pns;
                off_pns = sce.sf_idx[b];
                const first = noise_flag > 0;
                noise_flag -= 1;
                if (first) {
                    w.bits(noise_pre_bits, @intCast(diff + noise_pre));
                    continue;
                }
            } else if (sce.band_type[b] == BandType.intensity or sce.band_type[b] == BandType.intensity2) {
                diff = sce.sf_idx[b] - off_is;
                off_is = sce.sf_idx[b];
            } else {
                diff = sce.sf_idx[b] - off_sf;
                off_sf = sce.sf_idx[b];
            }
            diff += scale_diff_zero;
            // av_assert0(diff >= 0 && diff <= 120) in FFmpeg.
            std.debug.assert(diff >= 0 and diff <= 120);
            const d: usize = @intCast(diff);
            w.bits(@intCast(aac_tab.scalefactor_bits[d]), aac_tab.scalefactor_code[d]);
        }
    }
}

const testing = std.testing;
const signals = @import("../testing/signals.zig");

/// aacenc_vectors.c's float sample; "corr" keeps its first channel's
/// sample of the instant in `state[7]` (no other signal of a case uses it).
fn vectorSample(rng: *signals.Rng, signal: []const u8, gain: f32, specials: bool, c: usize, i: usize, state: *[8]i32) f32 {
    const bursts = std.mem.eql(u8, signal, "bursts");
    const v = if (std.mem.eql(u8, signal, "corr")) blk: {
        const own = signals.sample(rng, "noise", c, i, state, 16);
        if (c == 0) state[7] = own;
        break :blk if (c == 0) own else @divTrunc(state[7] * 3 + @divTrunc(own, 4), 4);
    } else if (std.mem.eql(u8, signal, "onsets")) blk: {
        const own = signals.sample(rng, "noise", c, i, state, 16);
        if ((i / 700) % 32 != 5) return @as(f32, @floatFromInt(own)) * (gain / 32768.0 / 128.0);
        break :blk own;
    } else signals.sample(rng, if (bursts) "noise" else signal, c, i, state, 16);
    if (bursts and (i / 700) % 4 != 0) return @as(f32, @floatFromInt(v)) * (gain / 32768.0 / 128.0);
    if (specials) {
        if (i % 397 == 11) return std.math.nan(f32);
        if (i % 401 == 23) return if (c & 1 != 0) -std.math.inf(f32) else std.math.inf(f32);
        if (i % 409 == 37) return 1e30;
    }
    return @as(f32, @floatFromInt(v)) * (gain / 32768.0);
}

/// A vector case's options, as av_dict_parse_string and avcodec_open2
/// set them (the few the cases use).
fn vectorOptions(text: []const u8) !Options {
    var o: Options = .{};
    if (std.mem.eql(u8, text, "-")) return o;
    var pairs = std.mem.splitScalar(u8, text, ':');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=').?;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (std.mem.eql(u8, key, "aac_coder")) {
            o.coder = std.meta.stringToEnum(Coder, value).?;
        } else if (std.mem.eql(u8, key, "flags")) {
            o.qscale = std.mem.indexOf(u8, value, "qscale") != null;
        } else if (std.mem.eql(u8, key, "global_quality")) {
            o.global_quality = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, key, "cutoff")) {
            o.cutoff = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, key, "profile")) {
            o.profile = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, key, "aac_ms")) {
            o.mid_side = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, key, "aac_is")) {
            o.intensity_stereo = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, key, "aac_pns")) {
            o.pns = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, key, "aac_tns")) {
            o.tns = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, key, "aac_pce")) {
            o.pce = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, key, "aac_rc")) {
            o.rc = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, key, "aac_nmr_speed")) {
            o.nmr_speed = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, key, "aac_allow_71wide")) {
            o.allow_71wide = try std.fmt.parseInt(i32, value, 10) != 0;
        } else return error.UnknownOption;
    }
    return o;
}

/// aacenc_vectors.c's output for every case of `vectors`, rendered from
/// the port.
fn renderVectors(gpa: std.mem.Allocator, w: *std.Io.Writer, vectors: []const u8) !void {
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "C ")) continue;
        try w.print("{s}\n", .{line});
        var f = std.mem.tokenizeScalar(u8, line[2..], ' ');
        _ = f.next().?; // the name
        const layout = try std.fmt.parseInt(u64, f.next().?[2..], 16);
        const rate = try std.fmt.parseInt(u32, f.next().?, 10);
        const bit_rate = try std.fmt.parseInt(i64, f.next().?, 10);
        const total = try std.fmt.parseInt(usize, f.next().?, 10);
        const signal = f.next().?;
        const gain: f32 = @floatFromInt(try std.fmt.parseInt(u32, f.next().?, 10));
        const specials = (try std.fmt.parseInt(u1, f.next().?, 10)) != 0;
        var options = try vectorOptions(f.next().?);
        options.bit_rate = bit_rate;

        const e = Encoder.init(gpa, rate, layout, options) catch |err| switch (err) {
            error.UnsupportedFormat, error.InvalidOption => {
                try w.writeAll("O EINVAL\n");
                continue;
            },
            else => |other| return other,
        };
        defer e.deinit();
        try w.print("O ok\nI {d} {d} {d} {x}\n", .{ e.bit_rate, frame_samples, initial_padding, e.extradata() });

        const channels: usize = e.channels;
        var rng: signals.Rng = .{ .state = 0x9E3779B9 ^ @as(u32, @intCast(channels * 1000003 + total)) };
        var state: [8]i32 = @splat(0);
        var planes: [max_channels][frame_samples]f32 = undefined;
        var views: [max_channels][]const f32 = undefined;
        for (&views, &planes) |*v, *p| v.* = p;
        const out = try gpa.alloc(u8, e.packetCapacity());
        defer gpa.free(out);
        var remaining: usize = initial_padding;
        var packets: i64 = 0;
        var failed = false;
        var start: usize = 0;
        while (start < total) : (start += frame_samples) {
            const n = @min(total - start, frame_samples);
            for (0..n) |i| {
                for (0..channels) |c| planes[c][i] = vectorSample(&rng, signal, gain, specials, c, start + i, &state);
            }
            remaining += n;
            const got = e.encodeFrame(views[0..channels], n, out) catch {
                try w.writeAll("E EINVAL\n");
                failed = true;
                break;
            };
            if (got) |packet| try renderPacket(w, packet, &packets, &remaining);
        }
        if (!failed) {
            while (try e.encodeFrame(null, 0, out)) |packet| try renderPacket(w, packet, &packets, &remaining);
        }
    }
}

fn renderPacket(w: *std.Io.Writer, packet: []const u8, packets: *i64, remaining: *usize) !void {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(packet, &digest, .{});
    const duration = @min(remaining.*, frame_samples);
    remaining.* -= duration;
    try w.print("P {d} {d} {d} {x}\n", .{ packets.* * frame_samples - initial_padding, duration, packet.len, digest });
    packets.* += 1;
}

test "every case encodes as FFmpeg's AAC encoder encodes it (vectors/aacenc.txt)" {
    const vectors = @embedFile("../testing/vectors/aacenc.txt");
    var rendered: std.Io.Writer.Allocating = .init(testing.allocator);
    defer rendered.deinit();
    try renderVectors(testing.allocator, &rendered.writer, vectors);
    try testing.expectEqualStrings(vectors, rendered.written());
}

const hostile = @import("../testing/hostile.zig");

/// Every layout the encoder takes: the channel configurations', then the
/// PCE table's.
const fuzz_layouts = blk: {
    var masks: [normal_layouts.len + pce_tab.configs.len]u64 = undefined;
    for (normal_layouts, 0..) |l, i| masks[i] = l.mask;
    for (pce_tab.configs, normal_layouts.len..) |c, i| masks[i] = c.mask;
    break :blk masks;
};

const fuzz_profiles = [_]i32{ profile_unknown, profile_aac_low, profile_mpeg2_aac_low, 2 };

/// The fuzz entry's input: raw f32 samples (any bits: NaN, infinities,
/// huge values), then the rate's index, the layout's index, the bit rate,
/// the coder, the quality (negative: none), the cutoff, mid/side,
/// intensity stereo, PNS, TNS, the PCE option, 7.1(wide), the profile's
/// index, the NMR coder's rate control and its speed. Every packet must
/// fit the encoder's capacity; the stream ends with the flush.
fn fuzzRun(smith: *std.testing.Smith) !u32 {
    var input: [2 * frame_samples * 8 * 4 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const rate = sample_rates[smith.valueRangeAtMost(u8, 0, sample_rates.len - 1)];
    const layout = fuzz_layouts[smith.valueRangeAtMost(u8, 0, fuzz_layouts.len - 1)];
    var options: Options = .{
        .bit_rate = @bitCast(smith.value(u64)),
        .coder = switch (smith.valueRangeAtMost(u8, 0, 2)) {
            0 => .twoloop,
            1 => .fast,
            else => .nmr,
        },
    };
    if (options.bit_rate < 0) options.bit_rate = 0;
    const quality = smith.value(i32);
    if (quality >= 0) {
        options.qscale = true;
        options.global_quality = quality;
    }
    options.cutoff = smith.value(i32);
    options.mid_side = smith.valueRangeAtMost(i32, -1, 1);
    options.intensity_stereo = smith.valueRangeAtMost(i32, -1, 1);
    options.pns = smith.valueRangeAtMost(i32, -1, 1);
    options.tns = smith.valueRangeAtMost(i32, -1, 1);
    options.pce = smith.valueRangeAtMost(i32, -1, 1);
    options.allow_71wide = smith.valueRangeAtMost(u8, 0, 1) != 0;
    options.profile = fuzz_profiles[smith.valueRangeAtMost(u8, 0, fuzz_profiles.len - 1)];
    options.rc = smith.valueRangeAtMost(i32, 0, 1);
    options.nmr_speed = smith.valueRangeAtMost(i32, 0, 4);
    const e = Encoder.init(testing.allocator, rate, layout, options) catch |err| switch (err) {
        error.InvalidOption => return 0, // the profile
        error.UnsupportedFormat => unreachable, // the rates and layouts above
        error.OutOfMemory => return err,
    };
    defer e.deinit();
    const channels: usize = e.channels;
    const frame_bytes = 4 * channels;
    const total = (len - len % frame_bytes) / frame_bytes;
    var planes: [max_channels][frame_samples]f32 = undefined;
    var views: [max_channels][]const f32 = undefined;
    for (&views, &planes) |*v, *p| v.* = p;
    const out = try testing.allocator.alloc(u8, e.packetCapacity());
    defer testing.allocator.free(out);
    var packets: u32 = 0;
    var start: usize = 0;
    var flushes: u32 = 0;
    while (true) {
        const got = if (start < total) blk: {
            const n = @min(total - start, frame_samples);
            for (0..n) |i| {
                for (0..channels) |c| planes[c][i] = @bitCast(std.mem.readInt(u32, input[((start + i) * channels + c) * 4 ..][0..4], .little));
            }
            start += n;
            break :blk e.encodeFrame(views[0..channels], n, out);
        } else blk: {
            flushes += 1;
            break :blk e.encodeFrame(null, 0, out);
        };
        const packet = got catch |err| switch (err) {
            error.InvalidInput => return packets,
            error.InvalidFrame => unreachable, // whole planes of at most a frame
        } orelse {
            if (start < total) continue; // the first frame's delay
            break;
        };
        try testing.expect(packet.len > 0 and packet.len <= out.len);
        packets += 1;
        // Two frames of input end within four flushes.
        try testing.expect(flushes <= 4);
    }
    return packets;
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    _ = try fuzzRun(smith);
}

/// Samples in [-1, 1) from a xorshift, as f32 bits.
fn seedSamples(comptime n: usize) [4 * n]u8 {
    @setEvalBranchQuota(8 * n + 1000);
    var out: [4 * n]u8 = undefined;
    var x: u32 = 0x12345678;
    for (0..n) |i| {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        const v: f32 = @as(f32, @floatFromInt(@as(i32, @bitCast(x)) >> 8)) / (1 << 23);
        out[4 * i ..][0..4].* = @bitCast(std.mem.nativeToLittle(u32, @bitCast(v)));
    }
    return out;
}

const seed_samples = seedSamples(2 * frame_samples * 2 + 100);
const none: u64 = @bitCast(@as(i64, -1));
const fuzz_corpus: []const []const u8 = &.{
    // The values: the rate's index, the layout's index, the bit rate, the
    // coder, the quality, the cutoff, mid/side, intensity stereo, PNS,
    // TNS, the PCE option, 7.1(wide), the profile's index, the NMR
    // coder's rate control and speed.
    hostile.fuzzSeed(&seed_samples, &.{ 4, 1, 0, 0, none, 0, none, 1, 1, 1, 0, 0, 0, 0, 0 }),
    hostile.fuzzSeed(&seed_samples, &.{ 3, 1, 128000, 1, none, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0 }),
    hostile.fuzzSeed(&seed_samples, &.{ 7, 0, 32000, 0, 236, 9000, none, 1, 1, 1, 1, 0, 2, 0, 0 }),
    hostile.fuzzSeed(&seed_samples, &.{ 3, 5, 0, 1, none, 0, none, 1, 1, 1, 0, 0, 0, 0, 0 }),
    hostile.fuzzSeed(&seed_samples, &.{ 3, normal_layouts.len + 26, 0, 0, none, 0, none, 1, 1, 1, 0, 0, 0, 0, 0 }),
    hostile.fuzzSeed(&(@as([4 * frame_samples * 2]u8, @splat(0x7f)) ++ @as([4 * frame_samples * 2]u8, @splat(0xff))), &.{ 0, 1, 640000, 0, none, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0 }),
    hostile.fuzzSeed("", &.{ 11, 1, 0, 1, none, 0, none, 1, 1, 1, 0, 0, 0, 0, 0 }),
    // The NMR coder: CBR, -q:a, ABR at its fastest, a PCE layout.
    hostile.fuzzSeed(&seed_samples, &.{ 4, 1, 0, 2, none, 0, none, 1, 1, 1, 0, 0, 0, 0, 0 }),
    hostile.fuzzSeed(&seed_samples, &.{ 3, 0, 32000, 2, 118, 0, none, 1, 1, 1, 0, 0, 0, 0, 2 }),
    hostile.fuzzSeed(&seed_samples, &.{ 4, 1, 64000, 2, none, 0, none, 1, 1, 1, 0, 0, 0, 1, 4 }),
    hostile.fuzzSeed(&seed_samples, &.{ 3, normal_layouts.len + 26, 0, 2, none, 0, none, 1, 1, 1, 0, 0, 0, 0, 1 }),
    hostile.fuzzSeed(&(@as([4 * frame_samples * 2]u8, @splat(0x7f)) ++ @as([4 * frame_samples * 2]u8, @splat(0xff))), &.{ 0, 1, 1, 2, none, 0, 1, 1, 1, 1, 0, 0, 0, 1, 3 }),
};

test "fuzz: the AAC encoder on arbitrary samples, layouts and options" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "every seed of the AAC encoder's fuzz entry encodes" {
    for (fuzz_corpus) |seed| {
        var smith: std.testing.Smith = .{ .in = seed };
        _ = try fuzzRun(&smith);
    }
}

test "mutation smoke: the AAC encoder on mutated seeds" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 16, 0x61616365);
}

const FailureCase = struct { layout: u64, coder: Coder };

fn encodeUnderFailures(gpa: std.mem.Allocator, case: FailureCase) !void {
    const e = try Encoder.init(gpa, 48000, case.layout, .{ .coder = case.coder });
    defer e.deinit();
    var plane: [frame_samples]f32 = @splat(0.25);
    var views: [8][]const f32 = @splat(&plane);
    const out = try gpa.alloc(u8, e.packetCapacity());
    defer gpa.free(out);
    _ = try e.encodeFrame(views[0..e.channels], frame_samples, out);
    _ = try e.encodeFrame(views[0..e.channels], frame_samples, out);
    while (try e.encodeFrame(null, 0, out)) |_| {}
}

test "the AAC encoder frees everything under every allocation and remap failure" {
    for ([_]Coder{ .twoloop, .nmr }) |c| {
        try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.both, FailureCase{ .layout = 0x3, .coder = c }, encodeUnderFailures);
        // A PCE layout.
        try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.both, FailureCase{ .layout = 0x60f, .coder = c }, encodeUnderFailures);
    }
}
