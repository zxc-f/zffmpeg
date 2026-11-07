// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/ac3enc.c, ac3enc_template.c,
// ac3enc_float.c, ac3enc.h, ac3dsp.c (float_to_fixed24_c,
// ac3_exponent_min_c, ac3_extract_exponents_c,
// ac3_sum_square_butterfly_float_c, ac3_update_bap_counts_c,
// ac3_compute_mantissa_size_c), audiodsp.c (vector_clipf_c), me_cmp.c
// (pix_abs16_c) and audio_frame_queue.c (the flush's sample count) at the
// pinned reference revision.
// Copyright (c) 2000 Fabrice Bellard
// Copyright (c) 2006-2011 Justin Ruggles <justin.ruggles@gmail.com>
// Copyright (c) 2006-2010 Prakash Punnoor <prakash@punnoor.de>
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's float AC-3 encoder (`ac3`, TODO.md T32c), packet for packet:
//! the KBD-windowed MDCT, channel coupling with its phase flags, stereo
//! rematrixing, exponent strategies and grouping, the constant bit rate
//! search over the SNR offset, mantissa quantization and the frame's two
//! CRCs, with every option of the encoder's AVOption table and the codec
//! context's bit rate, cutoff and audio service type. Planar float
//! samples in frames of 1536 per channel, in the channel order of
//! FFmpeg's layout; the encoder reorders them. It keeps one frame's last
//! block, so a stream needs one more packet than its frames when the last
//! frame leaves samples in that block (`flush`).

const std = @import("std");
const ac3 = @import("ac3.zig");
const ba = @import("ac3_bitalloc.zig");
const ac3dec = @import("ac3dec.zig");
const bits = @import("bits.zig");
const tx = @import("tx.zig");
const float_dsp = @import("float_dsp.zig");
const aac_tab = @import("aac_tab.zig");
const cconv = @import("../core/cconv.zig");
const options_zig = @import("../core/options.zig");

/// AC3_BLOCK_SIZE.
const block_size = 256;
/// AC3_MAX_BLOCKS: an AC-3 frame's blocks.
const num_blocks = 6;
/// The samples a frame codes, per channel (`avctx->frame_size`).
pub const frame_samples = block_size * num_blocks;
/// `avctx->initial_padding`: the MDCT's delay of one block.
pub const initial_padding = block_size;
/// AC3_MAX_CHANNELS: the coupling channel, five full-bandwidth channels
/// and the LFE.
const max_channels = 7;
const cpl_ch = 0;
const max_coefs = ba.max_coefs;
const max_cpl_bands = 18;

/// The largest frame: 640 kbit/s at 32 kHz, 1920 16-bit words.
pub const max_packet = 2 * 1920;

const exp_reuse = 0;
const exp_d15 = 1;
const exp_d25 = 2;
const exp_d45 = 3;

/// COEF_MAX of the float encoder: 1 - 2^-24.
const coef_max: f64 = 16777215.0 / 16777216.0;
const coef_min: f64 = -16777215.0 / 16777216.0;
/// NEW_CPL_COORD_THRESHOLD.
const new_cpl_coord_threshold: f64 = 0.03;
/// EXP_DIFF_THRESHOLD.
const exp_diff_threshold = 500;
/// PHASE_BAND_ENERGY_DENOMINATOR and PHASE_DIFF_ENERGY_FACTOR.
const phase_band_energy_denominator = 1 << 14;
const phase_diff_energy_factor = 1 << 4;

/// The AC3ENC_OPT_* values the options take.
pub const opt_none = -1;
pub const opt_auto = -1;
pub const opt_off = 0;
pub const opt_on = 1;
pub const opt_not_indicated = 0;
pub const opt_mode_on = 2;
pub const opt_mode_off = 1;
pub const opt_dsurex_dpliiz = 3;
pub const opt_large_room = 1;
pub const opt_small_room = 2;
pub const opt_downmix_ltrt = 1;
pub const opt_downmix_loro = 2;
pub const opt_downmix_dplii = 3;
pub const opt_adconv_standard = 0;
pub const opt_adconv_hdcd = 1;

/// The LEVEL_* gains of the mix level options, as floats.
const level_minus_3db: f32 = std.math.sqrt1_2;
const level_minus_4point5db: f32 = 0.5946035575013605;
const level_minus_6db: f32 = 0.5;
const level_zero: f32 = 0.0;

const cmixlev_options = [3]f32{ level_minus_3db, level_minus_4point5db, level_minus_6db };
const surmixlev_options = [3]f32{ level_minus_3db, level_minus_6db, level_zero };
/// `extmixlev_options`: ff_ac3_gain_levels' first eight.
const extmixlev_options = ac3dec.gain_levels[0..8];

/// AV_AUDIO_SERVICE_TYPE_*.
pub const ServiceType = struct {
    pub const main = 0;
    pub const effects = 1;
    pub const visually_impaired = 2;
    pub const hearing_impaired = 3;
    pub const dialogue = 4;
    pub const commentary = 5;
    pub const emergency = 6;
    pub const voice_over = 7;
    pub const karaoke = 8;
};

/// The encoder's options: ff_ac3_enc_options with their defaults, and the
/// codec context's `bit_rate`, `cutoff` and `audio_service_type`.
pub const Options = struct {
    /// `-b:a` in bit/s; 0 takes the default for the full-bandwidth
    /// channels, then the nearest of the 19 AC-3 rates.
    bit_rate: i64 = 0,
    /// `-cutoff` in Hz; 0 takes the bandwidth table's.
    cutoff: i32 = 0,
    audio_service_type: i32 = ServiceType.main,
    center_mixlev: f32 = level_minus_4point5db,
    surround_mixlev: f32 = level_minus_6db,
    mixing_level: i32 = opt_none,
    room_type: i32 = opt_none,
    per_frame_metadata: bool = false,
    copyright: i32 = opt_none,
    dialnorm: i32 = -31,
    dsur_mode: i32 = opt_none,
    original: i32 = opt_none,
    dmix_mode: i32 = opt_none,
    ltrt_cmixlev: f32 = -1.0,
    ltrt_surmixlev: f32 = -1.0,
    loro_cmixlev: f32 = -1.0,
    loro_surmixlev: f32 = -1.0,
    dsurex_mode: i32 = opt_none,
    dheadphone_mode: i32 = opt_none,
    ad_conv_type: i32 = opt_none,
    stereo_rematrixing: bool = true,
    channel_coupling: i32 = opt_auto,
    cpl_start_band: i32 = opt_auto,

    const int_min: f64 = std.math.minInt(i32);
    const int_max: f64 = std.math.maxInt(i32);

    /// ff_ac3_enc_options, and the codec context's `b`, `cutoff` and
    /// `audio_service_type` (options_table.h), with their ranges and named
    /// values.
    pub const option_specs = [_]options_zig.Spec{
        .{ .name = "b", .field = "bit_rate", .kind = .int64, .help = "set bitrate (in bits/s)", .min = 0, .max = @floatFromInt(std.math.maxInt(i64)) },
        .{ .name = "cutoff", .field = "cutoff", .kind = .int, .help = "set cutoff bandwidth", .min = int_min, .max = int_max },
        .{ .name = "audio_service_type", .field = "audio_service_type", .kind = .int, .help = "audio service type", .min = 0, .max = ServiceType.karaoke, .constants = &.{
            .{ .name = "ma", .value = ServiceType.main },              .{ .name = "ef", .value = ServiceType.effects },
            .{ .name = "vi", .value = ServiceType.visually_impaired }, .{ .name = "hi", .value = ServiceType.hearing_impaired },
            .{ .name = "di", .value = ServiceType.dialogue },          .{ .name = "co", .value = ServiceType.commentary },
            .{ .name = "em", .value = ServiceType.emergency },         .{ .name = "vo", .value = ServiceType.voice_over },
            .{ .name = "ka", .value = ServiceType.karaoke },
        } },
        .{ .name = "center_mixlev", .field = "center_mixlev", .kind = .float, .help = "Center Mix Level", .min = 0.0, .max = 1.0 },
        .{ .name = "surround_mixlev", .field = "surround_mixlev", .kind = .float, .help = "Surround Mix Level", .min = 0.0, .max = 1.0 },
        .{ .name = "mixing_level", .field = "mixing_level", .kind = .int, .help = "Mixing Level", .min = opt_none, .max = 111 },
        .{ .name = "room_type", .field = "room_type", .kind = .int, .help = "Room Type", .min = opt_none, .max = opt_small_room, .constants = &.{
            .{ .name = "notindicated", .value = opt_not_indicated }, .{ .name = "large", .value = opt_large_room }, .{ .name = "small", .value = opt_small_room },
        } },
        .{ .name = "per_frame_metadata", .field = "per_frame_metadata", .kind = .bool, .help = "Allow Changing Metadata Per-Frame", .min = 0, .max = 1 },
        .{ .name = "copyright", .field = "copyright", .kind = .int, .help = "Copyright Bit", .min = opt_none, .max = 1 },
        .{ .name = "dialnorm", .field = "dialnorm", .kind = .int, .help = "Dialogue Level (dB)", .min = -31, .max = -1 },
        .{ .name = "dsur_mode", .field = "dsur_mode", .kind = .int, .help = "Dolby Surround Mode", .min = opt_none, .max = opt_mode_on, .constants = &.{
            .{ .name = "notindicated", .value = opt_not_indicated }, .{ .name = "on", .value = opt_mode_on }, .{ .name = "off", .value = opt_mode_off },
        } },
        .{ .name = "original", .field = "original", .kind = .int, .help = "Original Bit Stream", .min = opt_none, .max = 1 },
        .{ .name = "dmix_mode", .field = "dmix_mode", .kind = .int, .help = "Preferred Stereo Downmix Mode", .min = opt_none, .max = opt_downmix_dplii, .constants = &.{
            .{ .name = "notindicated", .value = opt_not_indicated }, .{ .name = "ltrt", .value = opt_downmix_ltrt },
            .{ .name = "loro", .value = opt_downmix_loro },          .{ .name = "dplii", .value = opt_downmix_dplii },
        } },
        .{ .name = "ltrt_cmixlev", .field = "ltrt_cmixlev", .kind = .float, .help = "Lt/Rt Center Mix Level", .min = -1.0, .max = 2.0 },
        .{ .name = "ltrt_surmixlev", .field = "ltrt_surmixlev", .kind = .float, .help = "Lt/Rt Surround Mix Level", .min = -1.0, .max = 2.0 },
        .{ .name = "loro_cmixlev", .field = "loro_cmixlev", .kind = .float, .help = "Lo/Ro Center Mix Level", .min = -1.0, .max = 2.0 },
        .{ .name = "loro_surmixlev", .field = "loro_surmixlev", .kind = .float, .help = "Lo/Ro Surround Mix Level", .min = -1.0, .max = 2.0 },
        .{ .name = "dsurex_mode", .field = "dsurex_mode", .kind = .int, .help = "Dolby Surround EX Mode", .min = opt_none, .max = opt_dsurex_dpliiz, .constants = &.{
            .{ .name = "notindicated", .value = opt_not_indicated }, .{ .name = "on", .value = opt_mode_on },
            .{ .name = "off", .value = opt_mode_off },               .{ .name = "dpliiz", .value = opt_dsurex_dpliiz },
        } },
        .{ .name = "dheadphone_mode", .field = "dheadphone_mode", .kind = .int, .help = "Dolby Headphone Mode", .min = opt_none, .max = opt_mode_on, .constants = &.{
            .{ .name = "notindicated", .value = opt_not_indicated }, .{ .name = "on", .value = opt_mode_on }, .{ .name = "off", .value = opt_mode_off },
        } },
        .{ .name = "ad_conv_type", .field = "ad_conv_type", .kind = .int, .help = "A/D Converter Type", .min = opt_none, .max = opt_adconv_hdcd, .constants = &.{
            .{ .name = "standard", .value = opt_adconv_standard }, .{ .name = "hdcd", .value = opt_adconv_hdcd },
        } },
        .{ .name = "stereo_rematrixing", .field = "stereo_rematrixing", .kind = .bool, .help = "Stereo Rematrixing", .min = 0, .max = 1 },
        .{ .name = "channel_coupling", .field = "channel_coupling", .kind = .int, .help = "Channel Coupling", .min = opt_auto, .max = opt_on, .constants = &.{
            .{ .name = "auto", .value = opt_auto },
        } },
        .{ .name = "cpl_start_band", .field = "cpl_start_band", .kind = .int, .help = "Coupling Start Band", .min = opt_auto, .max = 15, .constants = &.{
            .{ .name = "auto", .value = opt_auto },
        } },
    };

    comptime {
        options_zig.check(Options);
    }
};

pub const Error = error{
    /// A sample rate other than 48, 44.1 and 32 kHz, or a layout not in
    /// ff_ac3_ch_layouts (CODEC_SAMPLERATES and CODEC_CH_LAYOUTS, which
    /// avcodec_open2 checks).
    UnsupportedFormat,
    /// An option the encoder refuses (AVERROR(EINVAL)): a negative cutoff,
    /// an audio service type the channels cannot carry, a room type
    /// without a mixing level, a mixing level below 80 dB.
    InvalidOption,
    OutOfMemory,
};

pub const FrameError = error{
    /// More samples than a frame, or planes of the wrong count or length.
    InvalidFrame,
    /// "Bit allocation failed. Try increasing the bitrate." (EINVAL): the
    /// frame's fixed bits do not fit, or no SNR offset does.
    BitAllocationFailed,
};

/// One audio block's state (AC3Block).
const Block = struct {
    new_rematrixing_strategy: bool = false,
    num_rematrixing_bands: u8 = 0,
    rematrixing_flags: [4]u8 = @splat(0),
    new_cpl_strategy: bool = false,
    cpl_in_use: bool = false,
    channel_in_cpl: [max_channels]bool = @splat(false),
    num_cpl_channels: u8 = 0,
    new_cpl_coords: [max_channels]u8 = @splat(0),
    cpl_master_exp: [max_channels]u8 = @splat(0),
    new_snr_offsets: bool = false,
    new_cpl_leak: bool = false,
    end_freq: [max_channels]i32 = @splat(0),
    grouped_exp: [max_channels][128]u8 = @splat(@splat(0)),
    psd: [max_channels][max_coefs]i16 = @splat(@splat(0)),
    band_psd: [max_channels][64]i16 = @splat(@splat(0)),
    mask: [max_channels][64]i16 = @splat(@splat(0)),
    qmant: [max_channels][max_coefs]i16 = @splat(@splat(0)),
    cpl_coord_exp: [max_channels][16]u8 = @splat(@splat(0)),
    cpl_coord_mant: [max_channels][16]u8 = @splat(@splat(0)),
};

/// `ff_ac3_ch_layouts`: the layouts the encoder takes.
pub const layouts = [_]u64{
    ac3.ch.front_center,
    ac3.ch.front_left | ac3.ch.front_right,
    ac3.ch.front_left | ac3.ch.front_right | ac3.ch.back_center,
    ac3.ch.front_left | ac3.ch.front_right | ac3.ch.front_center,
    ac3.ch.front_left | ac3.ch.front_right | ac3.ch.side_left | ac3.ch.side_right,
    ac3.ch.front_left | ac3.ch.front_right | ac3.ch.back_left | ac3.ch.back_right,
    ac3.ch.front_left | ac3.ch.front_right | ac3.ch.front_center | ac3.ch.back_center,
    ac3.ch.front_left | ac3.ch.front_right | ac3.ch.front_center | ac3.ch.side_left | ac3.ch.side_right,
    ac3.ch.front_left | ac3.ch.front_right | ac3.ch.front_center | ac3.ch.back_left | ac3.ch.back_right,
    ac3.ch.front_center | ac3.ch.low_frequency,
    ac3.ch.front_left | ac3.ch.front_right | ac3.ch.low_frequency,
    ac3.ch.front_left | ac3.ch.front_right | ac3.ch.back_center | ac3.ch.low_frequency,
    ac3.ch.front_left | ac3.ch.front_right | ac3.ch.front_center | ac3.ch.low_frequency,
    ac3.ch.front_left | ac3.ch.front_right | ac3.ch.front_center | ac3.ch.back_center | ac3.ch.low_frequency,
    ac3.ch.front_left | ac3.ch.front_right | ac3.ch.front_center | ac3.ch.low_frequency | ac3.ch.side_left | ac3.ch.side_right,
    ac3.ch.front_left | ac3.ch.front_right | ac3.ch.front_center | ac3.ch.low_frequency | ac3.ch.back_left | ac3.ch.back_right,
};

/// `ac3_enc_channel_map`: by channel mode and LFE, each AC-3 channel's
/// input channel.
const enc_channel_map = [8][2][6]u8{
    .{ .{ 0, 1, 0, 0, 0, 0 }, .{ 0, 1, 2, 0, 0, 0 } },
    .{ .{ 0, 0, 0, 0, 0, 0 }, .{ 0, 1, 0, 0, 0, 0 } },
    .{ .{ 0, 1, 0, 0, 0, 0 }, .{ 0, 1, 2, 0, 0, 0 } },
    .{ .{ 0, 2, 1, 0, 0, 0 }, .{ 0, 2, 1, 3, 0, 0 } },
    .{ .{ 0, 1, 2, 0, 0, 0 }, .{ 0, 1, 3, 2, 0, 0 } },
    .{ .{ 0, 2, 1, 3, 0, 0 }, .{ 0, 2, 1, 4, 3, 0 } },
    .{ .{ 0, 1, 2, 3, 0, 0 }, .{ 0, 1, 3, 4, 2, 0 } },
    .{ .{ 0, 2, 1, 3, 4, 0 }, .{ 0, 2, 1, 4, 5, 3 } },
};

/// `ac3_bandwidth_tab[fbw_channels-1][sample rate code][bit rate code]`.
const bandwidth_tab = [5][3][19]u8{
    .{
        .{ 0, 0, 0, 12, 16, 32, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48 },
        .{ 0, 0, 0, 16, 20, 36, 56, 56, 56, 56, 56, 56, 56, 56, 56, 56, 56, 56, 56 },
        .{ 0, 0, 0, 32, 40, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60 },
    },
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 20, 24, 32, 48, 48, 48, 48, 48, 48, 48, 48, 48 },
        .{ 0, 0, 0, 0, 0, 0, 4, 24, 28, 36, 56, 56, 56, 56, 56, 56, 56, 56, 56 },
        .{ 0, 0, 0, 0, 0, 0, 20, 44, 52, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60 },
    },
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 16, 24, 32, 40, 48, 48, 48, 48, 48, 48 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 4, 20, 28, 36, 44, 56, 56, 56, 56, 56, 56 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 20, 40, 48, 60, 60, 60, 60, 60, 60, 60, 60 },
    },
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12, 24, 32, 48, 48, 48, 48, 48, 48 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16, 28, 36, 56, 56, 56, 56, 56, 56 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32, 48, 60, 60, 60, 60, 60, 60, 60 },
    },
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 20, 32, 40, 48, 48, 48, 48 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12, 24, 36, 44, 56, 56, 56, 56 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 28, 44, 60, 60, 60, 60, 60, 60 },
    },
};

/// `ac3_coupling_start_tab[channel_mode-2][sample rate code][bit rate
/// code]`; -1 turns coupling off.
const coupling_start_tab = [6][3][19]i8{
    // 2/0
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 1, 1, 7, 8, 11, 12, -1, -1, -1, -1, -1, -1 },
        .{ 0, 0, 0, 0, 0, 0, 1, 3, 5, 7, 10, 12, 13, -1, -1, -1, -1, -1, -1 },
        .{ 0, 0, 0, 0, 1, 2, 2, 9, 13, 15, -1, -1, -1, -1, -1, -1, -1, -1, -1 },
    },
    // 3/0
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 6, 9, 11, 12, 13, -1, -1, -1, -1 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 6, 9, 11, 12, 13, -1, -1, -1, -1 },
        @splat(-1),
    },
    // 2/1
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 6, 9, 11, 12, 13, -1, -1, -1, -1 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 6, 9, 11, 12, 13, -1, -1, -1, -1 },
        @splat(-1),
    },
    // 3/1
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 2, 10, 11, 11, 12, 12, 14, -1 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 2, 10, 11, 11, 12, 12, 14, -1 },
        @splat(-1),
    },
    // 2/2
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 2, 10, 11, 11, 12, 12, 14, -1 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 2, 10, 11, 11, 12, 12, 14, -1 },
        @splat(-1),
    },
    // 3/2
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 6, 8, 11, 12, 12, -1, -1 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 6, 8, 11, 12, 12, -1, -1 },
        @splat(-1),
    },
};

/// `exponent_group_tab[coupling][exponent strategy-1][coefficients]`
/// (exponent_init).
const exponent_group_tab: [2][3][256]u8 = blk: {
    @setEvalBranchQuota(10000);
    var t: [2][3][256]u8 = @splat(@splat(@splat(0)));
    for (0..3) |expstr| {
        const grpsize = 3 << expstr;
        for (12..256) |i| {
            t[0][expstr][i] = (i + grpsize - 4) / grpsize;
            t[1][expstr][i] = i / grpsize;
        }
    }
    // The LFE.
    t[0][0][7] = 2;
    break :blk t;
};

/// `exp_strategy_reuse_tab`: by the blocks' count code and the reuse
/// interval.
const exp_strategy_reuse_tab = [4][6]u8{
    .{ exp_d15, exp_d15, exp_d15, exp_d15, exp_d15, exp_d15 },
    .{ exp_d15, exp_d15, exp_d15, exp_d15, exp_d15, exp_d15 },
    .{ exp_d25, exp_d25, exp_d15, exp_d15, exp_d15, exp_d15 },
    .{ exp_d45, exp_d25, exp_d25, exp_d15, exp_d15, exp_d15 },
};

/// `ff_ac3_bap_bits`.
const bap_bits = [16]u8{ 0, 0, 0, 3, 0, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16 };

/// The encoder's KBD window, alpha 5 over 256 samples.
const window: [block_size]f32 = aac_tab.kbdWindow(block_size, 5.0);

/// CRC16_POLY: x^16 + x^15 + x^2 + 1.
const crc16_poly: u32 = (1 << 0) | (1 << 2) | (1 << 15) | (1 << 16);

fn mulPoly(a_in: u32, b_in: u32, poly: u32) u32 {
    var a = a_in;
    var b = b_in;
    var c: u32 = 0;
    while (a != 0) {
        if (a & 1 != 0) c ^= b;
        a >>= 1;
        b <<= 1;
        if (b & (1 << 16) != 0) b ^= poly;
    }
    return c;
}

fn powPoly(a_in: u32, n_in: u32, poly: u32) u32 {
    var a = a_in;
    var n = n_in;
    var r: u32 = 1;
    while (n != 0) {
        if (n & 1 != 0) r = mulPoly(r, a, poly);
        a = mulPoly(a, a, poly);
        n >>= 1;
    }
    return r;
}

/// float_to_fixed24_c: `lrintf(x * 2^24)` stored into the `int32_t` (the
/// reference build's 64-bit conversion, its low 32 bits kept).
fn floatToFixed24(dst: []i32, src: []const f32) void {
    for (dst, src) |*d, s| d.* = @truncate(cconv.lrintf(s * (1 << 24)));
}

/// ac3_extract_exponents_c. `abs(INT_MIN)` is INT_MIN on the reference
/// build, so its exponent is 23 - 31, stored as a byte; a coefficient of
/// 2^24 or more gives such a value too (notes.md "AC-3 encoding").
fn extractExponents(exp: []u8, coef: []const i32) void {
    for (exp, coef) |*e, c| {
        const v: u32 = @abs(c);
        e.* = if (v != 0) @truncate(@as(u32, 23) -% std.math.log2_int(u32, v)) else 24;
    }
}

/// ac3_sum_square_butterfly_float_c.
fn sumSquareButterfly(sum: *[4]f32, coef0: []const f32, coef1: []const f32, len: usize) void {
    sum.* = @splat(0);
    for (0..len) |i| {
        const lt = coef0[i];
        const rt = coef1[i];
        const md = lt + rt;
        const sd = lt - rt;
        sum[0] += lt * lt;
        sum[1] += rt * rt;
        sum[2] += md * md;
        sum[3] += sd * sd;
    }
}

/// av_clipf: FFMIN(FFMAX(a, min), max), NaN giving `min`.
fn clipf(a: f32, min: f32, max: f32) f32 {
    const t = if (a > min) a else min;
    return if (t > max) max else t;
}

/// calc_cpl_coord of the float encoder.
fn calcCplCoord(energy_ch: f32, energy_cpl: f32) f32 {
    var coord: f32 = 0.125;
    if (energy_cpl > 0) coord *= @sqrt(energy_ch / energy_cpl);
    // FFMIN(coord, COEF_MAX) in double: COEF_MAX is exact in a float.
    return if (@as(f64, coord) > coef_max) @floatCast(coef_max) else coord;
}

/// sym_quant. Its products and shifts are int ones: a huge coefficient
/// (an exponent above 24) wraps the product and masks the shift count as
/// the reference build's `imul` and `sar` do (notes.md "AC-3 encoding").
fn symQuant(c: i32, e: u8, levels: i32) i32 {
    const p = levels *% c;
    const shift: u5 = @truncate(@as(u32, 24) -% e);
    return ((p >> shift) +% levels) >> 1;
}

/// asym_quant, with sym_quant's wrapping.
fn asymQuant(c_in: i32, e: u8, qbits: u5) i32 {
    const scaled: i32 = @bitCast(@as(u32, @bitCast(c_in)) << @as(u5, @truncate(e)));
    var c = ((scaled >> (24 - qbits)) +% 1) >> 1;
    const m: i32 = @as(i32, 1) << (qbits - 1);
    if (c >= m) c = m - 1;
    return c;
}

/// AC3Mant: the grouped mantissas' places and counts within a block.
const Mant = struct {
    qmant1: ?*i16 = null,
    qmant2: ?*i16 = null,
    qmant4: ?*i16 = null,
    mant1_cnt: u2 = 0,
    mant2_cnt: u2 = 0,
    mant4_cnt: u1 = 0,
};

pub const Encoder = struct {
    gpa: std.mem.Allocator,
    mdct: tx.Mdct,
    opt: Options,

    bitstream_id: u8,
    bitstream_mode: u8,
    bit_rate: i32,
    sample_rate: u32,
    sr_code: u2,
    frame_size_min: i32,
    frame_size: i32,
    frame_size_code: u8,
    crc_inv: [2]u16 = .{ 0, 0 },
    bits_written: i64 = 0,
    samples_written: i64 = 0,

    fbw_channels: u8,
    /// The full-bandwidth channels and the LFE.
    channels: u8,
    lfe_on: bool,
    /// The LFE's channel index, or none.
    lfe_channel: ?u8,
    has_center: bool,
    has_surround: bool,
    channel_mode: u3,
    channel_map: *const [6]u8,

    center_mix_level: u8 = 0,
    surround_mix_level: u8 = 0,
    ltrt_center_mix_level: u8 = 0,
    ltrt_surround_mix_level: u8 = 0,
    loro_center_mix_level: u8 = 0,
    loro_surround_mix_level: u8 = 0,
    audio_production_info: bool = false,
    extended_bsi_1: bool = false,
    extended_bsi_2: bool = false,

    cutoff: i32,
    bandwidth_code: u8 = 0,
    start_freq: [max_channels]i32 = @splat(0),
    cpl_end_freq: i32 = 0,

    cpl_on: bool = false,
    cpl_enabled: bool,
    phase_flags_in_use: bool = false,
    phase_flags: [max_cpl_bands]u8 = @splat(0),
    num_cpl_subbands: i32 = 0,
    num_cpl_bands: usize = 0,
    cpl_band_sizes: [max_cpl_bands]u8 = @splat(0),

    rematrixing_enabled: bool,

    slow_gain_code: u8 = 1,
    slow_decay_code: u8 = 2,
    fast_decay_code: u8 = 1,
    db_per_bit_code: u8 = 3,
    floor_code: u8 = 7,
    bit_alloc: ba.BitAllocParams = .{},
    coarse_snr_offset: i32 = 40,
    fast_gain_code: [max_channels]u8 = @splat(4),
    fine_snr_offset: [max_channels]i32 = @splat(0),
    frame_bits_fixed: i32 = 0,
    frame_bits: i32 = 0,
    exponent_bits: i32 = 0,

    /// The last block of the previous frame, per AC-3 channel.
    planar_samples: [max_channels - 1][block_size]f32 = @splat(@splat(0)),
    blocks: [num_blocks]Block = @splat(.{}),
    /// [channel][block][coefficient], as FFmpeg's buffers lie.
    mdct_coef: [max_channels][num_blocks][max_coefs]f32 = @splat(@splat(@splat(0))),
    fixed_coef: [max_channels][num_blocks][max_coefs]i32 = @splat(@splat(@splat(0))),
    exp: [max_channels][num_blocks][max_coefs]u8 = @splat(@splat(@splat(0))),
    /// `bap_buffer` and `bap1_buffer`, swapped by the search.
    bap: [2][max_channels][num_blocks][max_coefs]u8 = @splat(@splat(@splat(@splat(0)))),
    /// Which of `bap` is `bap_buffer`; `ref_bap` always points into it
    /// when the bits are counted (reset_block_bap).
    cur_bap: u1 = 0,
    exp_strategy: [max_channels][num_blocks]u8 = @splat(@splat(0)),
    exp_ref_block: [max_channels][num_blocks]u8 = @splat(@splat(0)),
    windowed: [2 * block_size]f32 = @splat(0),

    /// The frame queue's samples (audio_frame_queue.c): the padding, plus
    /// every frame's, minus each packet's.
    remaining_samples: i64 = initial_padding,
    got_frame: bool = false,

    /// ff_ac3_float_encode_init and ff_ac3_encode_init, with
    /// avcodec_open2's checks of the rate and the layout (`layout` a
    /// native channel mask in FFmpeg's channel order).
    pub fn init(gpa: std.mem.Allocator, sample_rate: u32, layout: u64, options: Options) Error!*Encoder {
        const sr_code: u2 = for (ac3.sample_rate_tab[0..3], 0..) |r, i| {
            if (r == sample_rate) break @intCast(i);
        } else return error.UnsupportedFormat;
        if (std.mem.indexOfScalar(u64, &layouts, layout) == null) return error.UnsupportedFormat;

        const e = try gpa.create(Encoder);
        errdefer gpa.destroy(e);
        // set_channel_info.
        const lfe_on = layout & ac3.ch.low_frequency != 0;
        const channels: u8 = @popCount(layout);
        const fbw: u8 = channels - @intFromBool(lfe_on);
        const mode: u3 = switch (layout & ~ac3.ch.low_frequency) {
            ac3.ch.front_center => ac3.ChannelMode.mono,
            ac3.ch.front_left | ac3.ch.front_right => ac3.ChannelMode.stereo,
            ac3.ch.front_left | ac3.ch.front_right | ac3.ch.front_center => ac3.ChannelMode.f3,
            ac3.ch.front_left | ac3.ch.front_right | ac3.ch.back_center => ac3.ChannelMode.f2r1,
            ac3.ch.front_left | ac3.ch.front_right | ac3.ch.front_center | ac3.ch.back_center => ac3.ChannelMode.f3r1,
            ac3.ch.front_left | ac3.ch.front_right | ac3.ch.back_left | ac3.ch.back_right,
            ac3.ch.front_left | ac3.ch.front_right | ac3.ch.side_left | ac3.ch.side_right,
            => ac3.ChannelMode.f2r2,
            else => ac3.ChannelMode.f3r2, // 5.0, side or back: `layouts` holds no other
        };
        e.* = .{
            .gpa = gpa,
            .mdct = undefined,
            .opt = options,
            .bitstream_id = 8,
            .bitstream_mode = 0,
            .bit_rate = 0,
            .sample_rate = sample_rate,
            .sr_code = sr_code,
            .frame_size_min = 0,
            .frame_size = 0,
            .frame_size_code = 0,
            .fbw_channels = fbw,
            .channels = channels,
            .lfe_on = lfe_on,
            .lfe_channel = if (lfe_on) fbw + 1 else null,
            .has_center = (mode & 1) != 0 and mode != ac3.ChannelMode.mono,
            .has_surround = (mode & 4) != 0,
            .channel_mode = mode,
            .channel_map = &enc_channel_map[mode][@intFromBool(lfe_on)],
            .cutoff = 0,
            .cpl_enabled = false,
            .rematrixing_enabled = false,
        };
        e.bit_alloc.sr_code = sr_code;
        try e.validateOptions();

        e.bitstream_mode = @intCast(options.audio_service_type);
        if (e.bitstream_mode == ServiceType.karaoke) e.bitstream_mode = 7;
        // crc_inv for both frame sizes.
        var fs58: u32 = @intCast(((e.frame_size >> 2) + (e.frame_size >> 4)) << 1);
        e.crc_inv[0] = @intCast(powPoly(crc16_poly >> 1, 8 * fs58 - 16, crc16_poly));
        if (sr_code == 1) {
            fs58 = @intCast((((e.frame_size + 2) >> 2) + ((e.frame_size + 2) >> 4)) << 1);
            e.crc_inv[1] = @intCast(powPoly(crc16_poly >> 1, 8 * fs58 - 16, crc16_poly));
        }
        e.setBandwidth();
        e.bitAllocInit();
        // ac3_float_mdct_init: the forward MDCT of 256 coefficients,
        // scaled by -2 / 512.
        e.mdct = tx.Mdct.init(gpa, block_size, false, -2.0 / @as(f32, 2 * block_size)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedLength => unreachable, // 256 is a power of two the transform takes
        };
        return e;
    }

    pub fn deinit(e: *Encoder) void {
        e.mdct.deinit();
        e.gpa.destroy(e);
    }

    /// `avctx->bit_rate` after opening: the AC-3 rate the encoder picked.
    pub fn bitRate(e: *const Encoder) i32 {
        return e.bit_rate;
    }

    /// validate_options (after set_channel_info).
    fn validateOptions(e: *Encoder) Error!void {
        var bit_rate = e.opt.bit_rate;
        if (bit_rate == 0) bit_rate = switch (e.fbw_channels) {
            1 => 96000,
            2 => 192000,
            3 => 320000,
            4 => 384000,
            else => 448000,
        };
        var best_br: i32 = 0;
        var best_code: u8 = 0;
        var best_diff: i64 = std.math.maxInt(i64);
        for (ac3.bitrate_tab, 0..) |rate, i| {
            const br: i32 = @intCast(rate * 1000);
            // llabs(br - avctx->bit_rate) in 64 bits.
            const diff: i64 = @intCast(@abs(@as(i128, br) - bit_rate));
            if (diff < best_diff) {
                best_br = br;
                best_code = @intCast(i);
                best_diff = diff;
            }
            if (best_diff == 0) break;
        }
        e.bit_rate = best_br;
        e.frame_size_code = best_code << 1;
        e.frame_size_min = 2 * @as(i32, ac3.frame_size_tab[e.frame_size_code][e.sr_code]);
        e.frame_size = e.frame_size_min;

        if (e.opt.cutoff < 0) return error.InvalidOption; // "invalid cutoff frequency"
        e.cutoff = @min(e.opt.cutoff, @as(i32, @intCast(e.sample_rate >> 1)));

        try e.validateMetadata();

        e.rematrixing_enabled = e.opt.stereo_rematrixing and e.channel_mode == ac3.ChannelMode.stereo;
        e.cpl_enabled = e.opt.channel_coupling != 0 and e.channel_mode >= ac3.ChannelMode.stereo;
    }

    /// validate_mix_level: the list's index within 0.01 of the option, or
    /// the default; the option becomes the list's value.
    fn validateMixLevel(opt_param: *f32, list: []const f32, default_value: u8, min_value: u8, ctx_param: *u8) void {
        var mixlev: ?usize = for (list, 0..) |v, i| {
            const x: f64 = opt_param.*;
            if (x < @as(f64, v) + 0.01 and x > @as(f64, v) - 0.01) break i;
        } else null;
        if (mixlev == null or mixlev.? < min_value) mixlev = default_value;
        opt_param.* = list[mixlev.?];
        ctx_param.* = @intCast(mixlev.?);
    }

    /// ac3_validate_metadata for AC-3.
    fn validateMetadata(e: *Encoder) Error!void {
        const opt = &e.opt;
        e.audio_production_info = false;
        e.extended_bsi_1 = false;
        e.extended_bsi_2 = false;
        if (e.channel_mode > ac3.ChannelMode.stereo and opt.dmix_mode != opt_none) e.extended_bsi_1 = true;
        if (e.has_center and (opt.ltrt_cmixlev >= 0 or opt.loro_cmixlev >= 0)) e.extended_bsi_1 = true;
        if (e.has_surround and (opt.ltrt_surmixlev >= 0 or opt.loro_surmixlev >= 0)) e.extended_bsi_1 = true;
        if (opt.mixing_level != opt_none or opt.room_type != opt_none) e.audio_production_info = true;
        if (e.channel_mode >= ac3.ChannelMode.f2r2 and opt.dsurex_mode != opt_none) e.extended_bsi_2 = true;
        if (e.channel_mode == ac3.ChannelMode.stereo and opt.dheadphone_mode != opt_none) e.extended_bsi_2 = true;
        if (opt.ad_conv_type != opt_none) e.extended_bsi_2 = true;

        if (e.has_center) validateMixLevel(&opt.center_mixlev, &cmixlev_options, 1, 0, &e.center_mix_level);
        if (e.has_surround) validateMixLevel(&opt.surround_mixlev, &surmixlev_options, 1, 0, &e.surround_mix_level);
        if (e.extended_bsi_1) {
            if (opt.dmix_mode == opt_none) opt.dmix_mode = opt_not_indicated;
            validateMixLevel(&opt.ltrt_cmixlev, extmixlev_options, 5, 0, &e.ltrt_center_mix_level);
            validateMixLevel(&opt.loro_cmixlev, extmixlev_options, 5, 0, &e.loro_center_mix_level);
            validateMixLevel(&opt.ltrt_surmixlev, extmixlev_options, 6, 3, &e.ltrt_surround_mix_level);
            validateMixLevel(&opt.loro_surmixlev, extmixlev_options, 6, 3, &e.loro_surround_mix_level);
        }
        // "invalid audio service type for the specified number of channels"
        const ast = opt.audio_service_type;
        if ((ast == ServiceType.karaoke and e.channels == 1) or
            ((ast == ServiceType.commentary or ast == ServiceType.emergency or ast == ServiceType.voice_over) and e.channels > 1))
            return error.InvalidOption;
        if (e.extended_bsi_2) {
            if (opt.dheadphone_mode == opt_none) opt.dheadphone_mode = opt_not_indicated;
            if (opt.dsurex_mode == opt_none) opt.dsurex_mode = opt_not_indicated;
            if (opt.ad_conv_type == opt_none) opt.ad_conv_type = opt_adconv_standard;
        }
        if (opt.copyright == opt_none) opt.copyright = opt_off;
        if (opt.original == opt_none) opt.original = opt_on;
        if (opt.dsur_mode == opt_none) opt.dsur_mode = opt_not_indicated;
        if (e.audio_production_info) {
            // "mixing_level must be set if room_type is set", "invalid
            // mixing level. must be between 80dB and 111dB"
            if (opt.mixing_level == opt_none or opt.mixing_level < 80) return error.InvalidOption;
            if (opt.room_type == opt_none) opt.room_type = opt_not_indicated;
        }
        if (e.extended_bsi_1 or e.extended_bsi_2) e.bitstream_id = 6;
    }

    /// set_bandwidth.
    fn setBandwidth(e: *Encoder) void {
        if (e.cutoff != 0) {
            const fbw_coeffs = @divTrunc(e.cutoff * 2 * max_coefs, @as(i32, @intCast(e.sample_rate)));
            e.bandwidth_code = @intCast(std.math.clamp(@divTrunc(fbw_coeffs - 73, 3), 0, 60));
        } else {
            e.bandwidth_code = bandwidth_tab[e.fbw_channels - 1][e.sr_code][e.frame_size_code / 2];
        }
        for (1..@as(usize, e.fbw_channels) + 1) |ch| {
            e.start_freq[ch] = 0;
            for (&e.blocks) |*b| b.end_freq[ch] = @as(i32, e.bandwidth_code) * 3 + 73;
        }
        // The LFE has 7 coefficients.
        if (e.lfe_channel) |lfe| {
            e.start_freq[lfe] = 0;
            for (&e.blocks) |*b| b.end_freq[lfe] = 7;
        }
        var cpl_start: i32 = undefined;
        if (e.cpl_enabled) {
            if (e.opt.cpl_start_band != opt_auto) {
                cpl_start = e.opt.cpl_start_band;
            } else {
                cpl_start = coupling_start_tab[e.channel_mode - 2][e.sr_code][e.frame_size_code / 2];
                if (cpl_start < 0) {
                    if (e.opt.channel_coupling == opt_auto) e.cpl_enabled = false else cpl_start = 15;
                }
            }
        }
        if (e.cpl_enabled) {
            const cpl_end_band: i32 = e.bandwidth_code / 4 + 3;
            const cpl_start_band = std.math.clamp(cpl_start, 0, @min(cpl_end_band - 1, 15));
            e.num_cpl_subbands = cpl_end_band - cpl_start_band;
            e.num_cpl_bands = 1;
            var at: usize = 0;
            e.cpl_band_sizes[0] = 12;
            var i = cpl_start_band + 1;
            while (i < cpl_end_band) : (i += 1) {
                if (ba.default_cpl_band_struct[@intCast(i)] != 0) {
                    e.cpl_band_sizes[at] += 12;
                } else {
                    e.num_cpl_bands += 1;
                    at += 1;
                    e.cpl_band_sizes[at] = 12;
                }
            }
            e.start_freq[cpl_ch] = cpl_start_band * 12 + 37;
            e.cpl_end_freq = cpl_end_band * 12 + 37;
            for (&e.blocks) |*b| b.end_freq[cpl_ch] = e.cpl_end_freq;
        }
    }

    /// bit_alloc_init and count_frame_bits_fixed.
    fn bitAllocInit(e: *Encoder) void {
        e.bit_alloc.slow_decay = ba.slow_decay_tab[e.slow_decay_code];
        e.bit_alloc.fast_decay = ba.fast_decay_tab[e.fast_decay_code];
        e.bit_alloc.slow_gain = ba.slow_gain_tab[e.slow_gain_code];
        e.bit_alloc.db_per_bit = ba.db_per_bit_tab[e.db_per_bit_code];
        e.bit_alloc.floor = ba.floor_tab[e.floor_code];
        e.bit_alloc.cpl_fast_leak = 0;
        e.bit_alloc.cpl_slow_leak = 0;

        const frame_bits_inc = [8]i32{ 0, 0, 2, 2, 2, 4, 2, 4 };
        const fbw: i32 = e.fbw_channels;
        var frame_bits: i32 = 16 + 49 + frame_bits_inc[e.channel_mode];
        for (0..num_blocks) |blk| {
            frame_bits += fbw; // block switch flags
            frame_bits += fbw; // dither flags
            frame_bits += 1; // dynamic range
            frame_bits += 1; // cplstre
            frame_bits += 2 * fbw; // exponent strategy
            if (e.lfe_on) frame_bits += 1;
            frame_bits += 1; // bit allocation parameters
            if (blk == 0) frame_bits += 2 + 2 + 2 + 2 + 3;
            frame_bits += 1; // snroffste
            frame_bits += 1; // delta bit allocation
            frame_bits += 1; // skipped data
        }
        frame_bits += 1; // auxiliary data
        frame_bits += 1 + 16; // CRC
        e.frame_bits_fixed = frame_bits;
    }

    /// ac3_adjust_frame_size: at 44.1 kHz, frames of the minimum size or
    /// two bytes more, so the average meets the bit rate.
    fn adjustFrameSize(e: *Encoder) void {
        while (e.bits_written >= e.bit_rate and e.samples_written >= e.sample_rate) {
            e.bits_written -= e.bit_rate;
            e.samples_written -= e.sample_rate;
        }
        const pad = e.bits_written * e.sample_rate < e.samples_written * e.bit_rate;
        e.frame_size = e.frame_size_min + 2 * @as(i32, @intFromBool(pad));
        e.bits_written += @as(i64, e.frame_size) * 8;
        e.samples_written += block_size * num_blocks;
    }

    /// One frame of planar float samples (`samples[ch]`, in the layout's
    /// order, each `count` long, at most 1536), or null to flush; the
    /// packet goes to `out`. Null when a flush has nothing left
    /// (ff_ac3_encode_frame with the frame queue).
    pub fn encodeFrame(e: *Encoder, samples: ?[]const []const f32, count: usize, out: *[max_packet]u8) FrameError!?[]u8 {
        var frame: [max_channels - 1][frame_samples]f32 = undefined;
        if (samples) |planes| {
            if (planes.len != e.channels or count > frame_samples) return error.InvalidFrame;
            for (planes, 0..) |p, ch| {
                if (p.len < count) return error.InvalidFrame;
                @memcpy(frame[ch][0..count], p[0..count]);
                @memset(frame[ch][count..], 0);
            }
            e.remaining_samples += @intCast(count);
            e.got_frame = true;
        } else {
            if (e.remaining_samples == 0 or !e.got_frame) return null;
            for (frame[0..e.channels]) |*p| p.* = @splat(0);
        }
        if (e.sr_code == 1) e.adjustFrameSize();

        e.applyMdct(&frame);
        e.cpl_on = e.cpl_enabled;
        e.computeCouplingStrategy();
        if (e.cpl_on) e.applyChannelCoupling();
        e.computeRematrixingStrategy();
        e.scaleCoefficients();

        e.applyRematrixing();
        e.extractAllExponents();
        e.computeExpStrategy();
        e.encodeExponents();
        try e.computeBitAllocation();
        e.groupExponents();
        e.quantizeMantissas();
        const len: usize = @intCast(e.frame_size);
        e.outputFrame(out[0..len]);

        e.remaining_samples -= @min(e.remaining_samples, frame_samples);
        return out[0..len];
    }

    /// apply_mdct: each block's 512 windowed samples, the previous block
    /// and this one, into 256 coefficients.
    fn applyMdct(e: *Encoder, frame: *const [max_channels - 1][frame_samples]f32) void {
        for (0..e.channels) |ch| {
            const input = &frame[e.channel_map[ch]];
            var prev: []const f32 = &e.planar_samples[ch];
            for (0..num_blocks) |blk| {
                const cur = input[blk * block_size ..][0..block_size];
                float_dsp.fmul(e.windowed[0..block_size], prev, &window, block_size);
                float_dsp.fmulReverse(e.windowed[block_size..], cur, &window, block_size);
                e.mdct.run(&e.mdct_coef[ch + 1][blk], &e.windowed);
                prev = cur;
            }
            @memcpy(&e.planar_samples[ch], prev);
        }
    }

    /// ff_ac3_compute_coupling_strategy.
    fn computeCouplingStrategy(e: *Encoder) void {
        const fbw: usize = e.fbw_channels;
        for (&e.blocks) |*b| {
            for (1..fbw + 1) |ch| b.channel_in_cpl[ch] = e.cpl_on;
        }
        var got_cpl_snr = false;
        var num_cpl_blocks: usize = 0;
        for (&e.blocks, 0..) |*b, blk| {
            b.num_cpl_channels = 0;
            for (1..fbw + 1) |ch| b.num_cpl_channels += @intFromBool(b.channel_in_cpl[ch]);
            b.cpl_in_use = b.num_cpl_channels > 1;
            num_cpl_blocks += @intFromBool(b.cpl_in_use);
            if (!b.cpl_in_use) {
                b.num_cpl_channels = 0;
                for (1..fbw + 1) |ch| b.channel_in_cpl[ch] = false;
            }
            b.new_cpl_strategy = blk == 0;
            if (blk != 0) {
                for (1..fbw + 1) |ch| {
                    if (b.channel_in_cpl[ch] != e.blocks[blk - 1].channel_in_cpl[ch]) {
                        b.new_cpl_strategy = true;
                        break;
                    }
                }
            }
            b.new_cpl_leak = b.new_cpl_strategy;
            if (blk == 0 or (b.cpl_in_use and !got_cpl_snr)) {
                b.new_snr_offsets = true;
                if (b.cpl_in_use) got_cpl_snr = true;
            } else {
                b.new_snr_offsets = false;
            }
        }
        if (num_cpl_blocks == 0) e.cpl_on = false;
        for (&e.blocks) |*b| {
            for (1..fbw + 1) |ch| {
                b.end_freq[ch] = if (b.channel_in_cpl[ch]) e.start_freq[cpl_ch] else @as(i32, e.bandwidth_code) * 3 + 73;
            }
        }
    }

    /// apply_channel_coupling of the float encoder.
    fn applyChannelCoupling(e: *Encoder) void {
        var cpl_coords: [num_blocks][max_channels][16]f32 = @splat(@splat(@splat(0)));
        var fixed_cpl_coords: [num_blocks][max_channels][16]i32 = @splat(@splat(@splat(0)));
        var energy: [num_blocks][max_channels][16]f32 = @splat(@splat(@splat(0)));
        const fbw: usize = e.fbw_channels;
        const nbands = e.num_cpl_bands;
        const start: usize = @intCast(e.start_freq[cpl_ch]);
        const cpl_end: usize = @intCast(e.cpl_end_freq);

        e.phase_flags_in_use = false;
        // The start aligned down, the length to a multiple of 32.
        const num_cpl_coefs: usize = std.mem.alignForward(usize, @as(usize, @intCast(e.num_cpl_subbands)) * 12 + 1, 32);
        const cpl_start: usize = @min(256, start - 1 + num_cpl_coefs) - num_cpl_coefs;

        if (e.channel_mode == ac3.ChannelMode.stereo) {
            // One phase strategy for the frame: a difference carrier where
            // it has 12 dB more energy and the band is within 42 dB of the
            // coded channels' in every coupled block.
            var phase_flags: [max_cpl_bands]u8 = @splat(0);
            @memset(phase_flags[0..nbands], 1);
            var cpl_blocks: usize = 0;
            for (&e.blocks, 0..) |*b, blk| {
                if (!b.cpl_in_use) continue;
                cpl_blocks += 1;
                var sum: [max_cpl_bands][4]f32 = undefined;
                var block_energy: [4]f32 = undefined;
                const left = &e.mdct_coef[1][blk];
                const right = &e.mdct_coef[2][blk];
                sumSquareButterfly(&block_energy, left, right, start);
                var i = start;
                for (0..nbands) |bnd| {
                    sumSquareButterfly(&sum[bnd], left[i..], right[i..], e.cpl_band_sizes[bnd]);
                    energy[blk][1][bnd] = sum[bnd][0];
                    energy[blk][2][bnd] = sum[bnd][1];
                    block_energy[0] += sum[bnd][0];
                    block_energy[1] += sum[bnd][1];
                    i += e.cpl_band_sizes[bnd];
                }
                const max_energy = if (block_energy[0] > block_energy[1]) block_energy[0] else block_energy[1];
                for (0..nbands) |bnd| {
                    const band_energy = if (sum[bnd][0] > sum[bnd][1]) sum[bnd][0] else sum[bnd][1];
                    const significant = band_energy > max_energy / phase_band_energy_denominator;
                    phase_flags[bnd] &= @intFromBool(significant and sum[bnd][3] / phase_diff_energy_factor > sum[bnd][2]);
                }
            }
            for (0..nbands) |bnd| {
                const phase: u8 = @intFromBool(phase_flags[bnd] != 0 and cpl_blocks != 0);
                e.phase_flags[bnd] = phase;
                if (phase != 0) e.phase_flags_in_use = true;
            }
        }

        // The coupling channel from the full-bandwidth channels.
        for (&e.blocks, 0..) |*b, blk| {
            if (!b.cpl_in_use) continue;
            const cpl_coef = e.mdct_coef[cpl_ch][blk][cpl_start..][0..num_cpl_coefs];
            @memset(cpl_coef, 0);
            for (1..fbw + 1) |ch| {
                if (!b.channel_in_cpl[ch]) continue;
                const ch_coef = e.mdct_coef[ch][blk][cpl_start..][0..num_cpl_coefs];
                for (cpl_coef, ch_coef) |*c, v| c.* += v;
            }
            if (e.channel_mode == ac3.ChannelMode.stereo) {
                var i = start;
                for (0..nbands) |bnd| {
                    if (e.phase_flags[bnd] != 0) {
                        for (0..e.cpl_band_sizes[bnd]) |j| e.mdct_coef[cpl_ch][blk][i + j] = e.mdct_coef[1][blk][i + j] - e.mdct_coef[2][blk][i + j];
                    }
                    i += e.cpl_band_sizes[bnd];
                }
            }
            // clip_coefficients: vector_clipf to the range a mantissa takes.
            for (cpl_coef) |*c| c.* = clipf(c.*, @floatCast(coef_min), @floatCast(coef_max));
        }

        // Each band's energy in the coupling channel (and, but in stereo,
        // whose energies the phase analysis filled, each coupled channel).
        {
            var bnd: usize = 0;
            var i = start;
            const last_ch: usize = if (e.channel_mode == ac3.ChannelMode.stereo) cpl_ch else fbw;
            while (i < cpl_end) : (bnd += 1) {
                const band_size = e.cpl_band_sizes[bnd];
                for (0..last_ch + 1) |ch| {
                    for (&e.blocks, 0..) |*b, blk| {
                        if (!b.cpl_in_use or (ch > cpl_ch and !b.channel_in_cpl[ch])) continue;
                        for (0..band_size) |j| {
                            const v = e.mdct_coef[ch][blk][i + j];
                            energy[blk][ch][bnd] += v * v;
                        }
                    }
                }
                i += band_size;
            }
        }

        // Every coupled block's coordinates.
        for (&e.blocks, 0..) |*b, blk| {
            if (!b.cpl_in_use) continue;
            for (1..fbw + 1) |ch| {
                if (!b.channel_in_cpl[ch]) continue;
                for (0..nbands) |bnd| cpl_coords[blk][ch][bnd] = calcCplCoord(energy[blk][ch][bnd], energy[blk][cpl_ch][bnd]);
            }
        }

        // Which blocks send new coordinates.
        for (&e.blocks, 0..) |*b, blk| {
            b.new_cpl_coords = @splat(0);
            if (!b.cpl_in_use) continue;
            if (blk == 0 or !e.blocks[blk - 1].cpl_in_use) {
                for (1..fbw + 1) |ch| b.new_cpl_coords[ch] = 1;
            } else {
                const b0 = &e.blocks[blk - 1];
                for (1..fbw + 1) |ch| {
                    if (!b.channel_in_cpl[ch]) continue;
                    if (!b0.channel_in_cpl[ch]) {
                        b.new_cpl_coords[ch] = 1;
                    } else {
                        var coord_diff: f32 = 0;
                        for (0..nbands) |bnd| coord_diff += @abs(cpl_coords[blk - 1][ch][bnd] - cpl_coords[blk][ch][bnd]);
                        coord_diff /= @floatFromInt(nbands);
                        if (@as(f64, coord_diff) > new_cpl_coord_threshold) b.new_cpl_coords[ch] = 1;
                    }
                }
            }
        }

        // The final coordinates, over the blocks that reuse them.
        for (0..nbands) |bnd| {
            var blk: usize = 0;
            while (blk < num_blocks) {
                const b = &e.blocks[blk];
                if (!b.cpl_in_use) {
                    blk += 1;
                    continue;
                }
                var blk1: usize = undefined;
                for (1..fbw + 1) |ch| {
                    if (!b.channel_in_cpl[ch]) continue;
                    var energy_cpl = energy[blk][cpl_ch][bnd];
                    var energy_ch = energy[blk][ch][bnd];
                    blk1 = blk + 1;
                    while (blk1 < num_blocks and e.blocks[blk1].new_cpl_coords[ch] == 0) {
                        if (e.blocks[blk1].cpl_in_use) {
                            energy_cpl += energy[blk1][cpl_ch][bnd];
                            energy_ch += energy[blk1][ch][bnd];
                        }
                        blk1 += 1;
                    }
                    cpl_coords[blk][ch][bnd] = calcCplCoord(energy_ch, energy_cpl);
                }
                // A coupled block has at least two coupled channels, so
                // the loop set `blk1`.
                blk = blk1;
            }
        }

        // The coordinates' exponents and mantissas.
        for (&e.blocks, 0..) |*b, blk| {
            if (!b.cpl_in_use) continue;
            for (1..fbw + 1) |ch| {
                floatToFixed24(&fixed_cpl_coords[blk][ch], &cpl_coords[blk][ch]);
                extractExponents(&b.cpl_coord_exp[ch], &fixed_cpl_coords[blk][ch]);
            }
            for (1..fbw + 1) |ch| {
                if (b.new_cpl_coords[ch] == 0) continue;
                var min_exp: i32 = b.cpl_coord_exp[ch][0];
                var max_exp: i32 = min_exp;
                for (1..nbands) |bnd| {
                    const x: i32 = b.cpl_coord_exp[ch][bnd];
                    min_exp = @min(x, min_exp);
                    max_exp = @max(x, max_exp);
                }
                var master_exp: i32 = @divTrunc((max_exp - 15) + 2, 3);
                master_exp = @max(master_exp, 0);
                while (min_exp < master_exp * 3) master_exp -= 1;
                for (0..nbands) |bnd| {
                    b.cpl_coord_exp[ch][bnd] = @intCast(std.math.clamp(@as(i32, b.cpl_coord_exp[ch][bnd]) - master_exp * 3, 0, 15));
                }
                b.cpl_master_exp[ch] = @intCast(master_exp);
                for (0..nbands) |bnd| {
                    const cpl_exp: i32 = b.cpl_coord_exp[ch][bnd];
                    // The coordinates lie in [0, 1): the shift stays
                    // below 30 and keeps the value (see the C).
                    var cpl_mant: i32 = (fixed_cpl_coords[blk][ch][bnd] << @intCast(5 + cpl_exp + master_exp * 3)) >> 24;
                    if (cpl_exp == 15) cpl_mant >>= 1 else cpl_mant -= 16;
                    b.cpl_coord_mant[ch][bnd] = @intCast(cpl_mant);
                }
            }
        }
    }

    /// compute_rematrixing_strategy.
    fn computeRematrixingStrategy(e: *Encoder) void {
        if (e.channel_mode != ac3.ChannelMode.stereo) return;
        for (&e.blocks, 0..) |*b, blk| {
            b.new_rematrixing_strategy = blk == 0;
            b.num_rematrixing_bands = 4;
            if (b.cpl_in_use) {
                b.num_rematrixing_bands -= @intFromBool(e.start_freq[cpl_ch] <= 61);
                b.num_rematrixing_bands -= @intFromBool(e.start_freq[cpl_ch] == 37);
                if (blk != 0 and b.num_rematrixing_bands != e.blocks[blk - 1].num_rematrixing_bands) b.new_rematrixing_strategy = true;
            }
            const nb_coefs: i32 = @min(b.end_freq[1], b.end_freq[2]);
            if (!e.rematrixing_enabled) continue;
            for (0..b.num_rematrixing_bands) |bnd| {
                const band_start: i32 = ba.rematrix_band_tab[bnd];
                const band_end: i32 = @min(nb_coefs, @as(i32, ba.rematrix_band_tab[bnd + 1]));
                var sum: [4]f32 = undefined;
                const s: usize = @intCast(band_start);
                sumSquareButterfly(&sum, e.mdct_coef[1][blk][s..], e.mdct_coef[2][blk][s..], @intCast(@max(band_end - band_start, 0)));
                const lr = if (sum[0] > sum[1]) sum[1] else sum[0];
                const ms = if (sum[2] > sum[3]) sum[3] else sum[2];
                b.rematrixing_flags[bnd] = @intFromBool(ms < lr);
                if (blk != 0 and b.rematrixing_flags[bnd] != e.blocks[blk - 1].rematrixing_flags[bnd]) b.new_rematrixing_strategy = true;
            }
        }
    }

    /// scale_coefficients: the coded channels' coefficients to 24-bit
    /// fixed point, the coupling channel's when coupling is on.
    fn scaleCoefficients(e: *Encoder) void {
        const first: usize = @intFromBool(!e.cpl_on);
        for (first..@as(usize, e.channels) + 1) |ch| {
            for (0..num_blocks) |blk| floatToFixed24(&e.fixed_coef[ch][blk], &e.mdct_coef[ch][blk]);
        }
    }

    /// ac3_apply_rematrixing. The int sums wrap on huge coefficients as
    /// the reference build's (notes.md "AC-3 encoding").
    fn applyRematrixing(e: *Encoder) void {
        if (!e.rematrixing_enabled) return;
        var flags: *const [4]u8 = undefined;
        for (&e.blocks, 0..) |*b, blk| {
            if (b.new_rematrixing_strategy) flags = &b.rematrixing_flags;
            const nb_coefs: i32 = @min(b.end_freq[1], b.end_freq[2]);
            for (0..b.num_rematrixing_bands) |bnd| {
                if (flags[bnd] == 0) continue;
                const band_start: usize = ba.rematrix_band_tab[bnd];
                const band_end: i32 = @min(nb_coefs, @as(i32, ba.rematrix_band_tab[bnd + 1]));
                var i = band_start;
                while (@as(i32, @intCast(i)) < band_end) : (i += 1) {
                    const lt = e.fixed_coef[1][blk][i];
                    const rt = e.fixed_coef[2][blk][i];
                    e.fixed_coef[1][blk][i] = (lt +% rt) >> 1;
                    e.fixed_coef[2][blk][i] = (lt -% rt) >> 1;
                }
            }
        }
    }

    /// extract_exponents: every coded channel's, all 256 of each block.
    fn extractAllExponents(e: *Encoder) void {
        const first: usize = @intFromBool(!e.cpl_on);
        for (first..@as(usize, e.channels) + 1) |ch| {
            for (0..num_blocks) |blk| extractExponents(&e.exp[ch][blk], &e.fixed_coef[ch][blk]);
        }
    }

    /// compute_exp_strategy.
    fn computeExpStrategy(e: *Encoder) void {
        const first: usize = @intFromBool(!e.cpl_on);
        for (first..@as(usize, e.fbw_channels) + 1) |ch| {
            const strategy = &e.exp_strategy[ch];
            strategy[0] = exp_d15; // EXP_NEW
            for (1..num_blocks) |blk| {
                if (ch == cpl_ch) {
                    if (!e.blocks[blk - 1].cpl_in_use) {
                        strategy[blk] = exp_d15;
                        continue;
                    } else if (!e.blocks[blk].cpl_in_use) {
                        strategy[blk] = exp_reuse;
                        continue;
                    }
                } else if (e.blocks[blk].channel_in_cpl[ch] != e.blocks[blk - 1].channel_in_cpl[ch]) {
                    strategy[blk] = exp_d15;
                    continue;
                }
                // pix_abs16_c over the block's 256 exponents.
                var exp_diff: i32 = 0;
                for (e.exp[ch][blk], e.exp[ch][blk - 1]) |a, b| exp_diff += @intCast(@abs(@as(i32, a) - b));
                strategy[blk] = exp_reuse;
                if (ch == cpl_ch) {
                    const limit = @divTrunc(exp_diff_threshold * (e.blocks[blk].end_freq[ch] - e.start_freq[ch]), max_coefs);
                    if (exp_diff > limit) strategy[blk] = exp_d15;
                } else if (exp_diff > exp_diff_threshold) {
                    strategy[blk] = exp_d15;
                }
            }
            // Exponents sent often are coded coarsely.
            var blk: usize = 0;
            while (blk < num_blocks) {
                var blk1 = blk + 1;
                while (blk1 < num_blocks and strategy[blk1] == exp_reuse) blk1 += 1;
                strategy[blk] = exp_strategy_reuse_tab[3][blk1 - blk - 1];
                blk = blk1;
            }
        }
        if (e.lfe_channel) |lfe| {
            e.exp_strategy[lfe][0] = exp_d15;
            for (1..num_blocks) |blk| e.exp_strategy[lfe][blk] = exp_reuse;
        }
    }

    /// encode_exponents_blk_ch on `row` from `base` (the start frequency;
    /// the coupling channel's DC exponent goes one before it).
    fn encodeExponentsBlkCh(row: *[max_coefs]u8, base: usize, nb_exps: usize, strategy: u8, cpl: bool) void {
        const c: usize = @intFromBool(cpl);
        const nb_groups: usize = @as(usize, exponent_group_tab[c][strategy - 1][nb_exps]) * 3;
        const exp = row[base - c ..];
        // Index 0 of FFmpeg's `exp` is `exp[c]` here.
        switch (strategy) {
            exp_d25 => {
                var k: usize = 1 - c;
                for (1..nb_groups + 1) |i| {
                    var exp_min = exp[c + k];
                    if (exp[c + k + 1] < exp_min) exp_min = exp[c + k + 1];
                    exp[c + i - c] = exp_min;
                    k += 2;
                }
            },
            exp_d45 => {
                var k: usize = 1 - c;
                for (1..nb_groups + 1) |i| {
                    var exp_min = exp[c + k];
                    for (1..4) |j| {
                        if (exp[c + k + j] < exp_min) exp_min = exp[c + k + j];
                    }
                    exp[c + i - c] = exp_min;
                    k += 4;
                }
            },
            else => {},
        }
        // The DC exponent's limit.
        if (!cpl and exp[c] > 15) exp[c] = 15;
        // Deltas of at most 2 between groups, so they can be coded.
        for (1..nb_groups + 1) |i| exp[c + i] = @truncate(@min(@as(u32, exp[c + i]), @as(u32, exp[c + i - 1]) + 2));
        var i: usize = nb_groups;
        while (i > 0) {
            i -= 1;
            exp[c + i] = @truncate(@min(@as(u32, exp[c + i]), @as(u32, exp[c + i + 1]) + 2));
        }
        if (cpl) exp[0] = exp[c] & ~@as(u8, 1);
        // The exponents the decoder will see.
        switch (strategy) {
            exp_d25 => {
                var k: usize = nb_groups * 2 - c;
                var g = nb_groups;
                while (g > 0) : (g -= 1) {
                    const exp1 = exp[c + g - c];
                    exp[c + k] = exp1;
                    k -= 1;
                    exp[c + k] = exp1;
                    k -%= 1;
                }
            },
            exp_d45 => {
                var k: usize = nb_groups * 4 - c;
                var g = nb_groups;
                while (g > 0) : (g -= 1) {
                    const v = exp[c + g - c];
                    exp[c + k] = v;
                    exp[c + k - 1] = v;
                    exp[c + k - 2] = v;
                    exp[c + k - 3] = v;
                    k -%= 4;
                }
            },
            else => {},
        }
    }

    /// encode_exponents.
    fn encodeExponents(e: *Encoder) void {
        const first: usize = @intFromBool(!e.cpl_on);
        for (first..@as(usize, e.channels) + 1) |ch| {
            const strategy = &e.exp_strategy[ch];
            const cpl = ch == cpl_ch;
            const start: usize = @intCast(e.start_freq[ch]);
            var blk: usize = 0;
            while (blk < num_blocks) {
                const b = &e.blocks[blk];
                if (cpl and !b.cpl_in_use) {
                    blk += 1;
                    continue;
                }
                const nb_coefs: usize = @intCast(b.end_freq[ch] - e.start_freq[ch]);
                var blk1 = blk + 1;
                e.exp_ref_block[ch][blk] = @intCast(blk);
                while (blk1 < num_blocks and strategy[blk1] == exp_reuse) {
                    e.exp_ref_block[ch][blk1] = @intCast(blk);
                    blk1 += 1;
                }
                const num_reuse_blocks = blk1 - blk - 1;
                // ac3_exponent_min_c: the reuse blocks' minimum.
                if (num_reuse_blocks != 0) {
                    for (0..max_coefs) |i| {
                        var min_exp = e.exp[ch][blk][i];
                        for (1..num_reuse_blocks + 1) |r| {
                            if (e.exp[ch][blk + r][i] < min_exp) min_exp = e.exp[ch][blk + r][i];
                        }
                        e.exp[ch][blk][i] = min_exp;
                    }
                }
                encodeExponentsBlkCh(&e.exp[ch][blk], start, nb_coefs, strategy[blk], cpl);
                blk = blk1;
            }
        }
    }

    /// count_exponent_bits.
    fn countExponentBits(e: *const Encoder) i32 {
        var bit_count: i32 = 0;
        for (&e.blocks, 0..) |*b, blk| {
            for (@as(usize, @intFromBool(!b.cpl_in_use))..@as(usize, e.channels) + 1) |ch| {
                const strategy = e.exp_strategy[ch][blk];
                if (strategy == exp_reuse) continue;
                const c: usize = @intFromBool(ch == cpl_ch);
                const nb_coefs: usize = @intCast(b.end_freq[ch] - e.start_freq[ch]);
                const nb_groups: i32 = exponent_group_tab[c][strategy - 1][nb_coefs];
                bit_count += 4 + nb_groups * 7;
            }
        }
        return bit_count;
    }

    /// ac3_group_exponents.
    fn groupExponents(e: *Encoder) void {
        for (&e.blocks, 0..) |*b, blk| {
            for (@as(usize, @intFromBool(!b.cpl_in_use))..@as(usize, e.channels) + 1) |ch| {
                const strategy = e.exp_strategy[ch][blk];
                if (strategy == exp_reuse) continue;
                const c: usize = @intFromBool(ch == cpl_ch);
                const group_size: usize = strategy + @as(usize, @intFromBool(strategy == exp_d45));
                const start: usize = @intCast(e.start_freq[ch]);
                const nb_groups: usize = exponent_group_tab[c][strategy - 1][@intCast(b.end_freq[ch] - e.start_freq[ch])];
                const row = &e.exp[ch][blk];
                var p: usize = start - c;
                var exp1: i32 = row[p];
                p += 1;
                b.grouped_exp[ch][0] = @intCast(exp1);
                for (1..nb_groups + 1) |i| {
                    var deltas: [3]i32 = undefined;
                    for (&deltas) |*d| {
                        const exp0 = exp1;
                        exp1 = row[p];
                        p += group_size;
                        d.* = exp1 - exp0 + 2;
                    }
                    b.grouped_exp[ch][i] = @truncate(@as(u32, @bitCast((deltas[0] * 5 + deltas[1]) * 5 + deltas[2])));
                }
            }
        }
    }

    /// count_frame_bits.
    fn countFrameBits(e: *Encoder) void {
        var frame_bits: i32 = 0;
        const fbw: i32 = e.fbw_channels;
        if (e.audio_production_info) frame_bits += 7;
        if (e.bitstream_id == 6) {
            if (e.extended_bsi_1) frame_bits += 14;
            if (e.extended_bsi_2) frame_bits += 14;
        }
        for (&e.blocks, 0..) |*b, blk| {
            if (b.new_cpl_strategy) {
                frame_bits += 1;
                if (b.cpl_in_use) {
                    frame_bits += fbw;
                    if (e.channel_mode == ac3.ChannelMode.stereo) frame_bits += 1;
                    frame_bits += 4 + 4;
                    frame_bits += e.num_cpl_subbands - 1;
                }
            }
            if (b.cpl_in_use) {
                var cpl_coords_exist = false;
                for (1..@as(usize, e.fbw_channels) + 1) |ch| {
                    if (!b.channel_in_cpl[ch]) continue;
                    frame_bits += 1;
                    if (b.new_cpl_coords[ch] != 0) {
                        cpl_coords_exist = true;
                        frame_bits += 2;
                        frame_bits += (4 + 4) * @as(i32, @intCast(e.num_cpl_bands));
                    }
                }
                if (e.channel_mode == ac3.ChannelMode.stereo and e.phase_flags_in_use and cpl_coords_exist) frame_bits += @intCast(e.num_cpl_bands);
            }
            if (e.channel_mode == ac3.ChannelMode.stereo) {
                frame_bits += 1;
                if (b.new_rematrixing_strategy) frame_bits += b.num_rematrixing_bands;
            }
            for (1..@as(usize, e.fbw_channels) + 1) |ch| {
                if (e.exp_strategy[ch][blk] != exp_reuse) {
                    if (!b.channel_in_cpl[ch]) frame_bits += 6;
                    frame_bits += 2;
                }
            }
            if (b.cpl_in_use) frame_bits += 2;
            if (b.new_snr_offsets) frame_bits += 6 + (@as(i32, e.channels) + @intFromBool(b.cpl_in_use)) * (4 + 3);
            if (b.cpl_in_use) {
                frame_bits += 1;
                if (b.new_cpl_leak) frame_bits += 3 + 3;
            }
        }
        e.frame_bits = e.frame_bits_fixed + frame_bits;
    }

    /// bit_alloc_masking: the PSD and the masking curve of every block
    /// that sends exponents.
    fn bitAllocMasking(e: *Encoder) void {
        for (&e.blocks, 0..) |*b, blk| {
            for (@as(usize, @intFromBool(!b.cpl_in_use))..@as(usize, e.channels) + 1) |ch| {
                if (e.exp_strategy[ch][blk] == exp_reuse) continue;
                const start: usize = @intCast(e.start_freq[ch]);
                const end: usize = @intCast(b.end_freq[ch]);
                // FFmpeg passes the uint8_t exponents as int8_t.
                const exps: *const [max_coefs]i8 = @ptrCast(&e.exp[ch][blk]);
                ba.calcPsd(exps, start, end, &b.psd[ch], &b.band_psd[ch]);
                const is_lfe = if (e.lfe_channel) |lfe| ch == lfe else false;
                const none: ba.Dba = .{ .mode = 2, .nsegs = 0, .offsets = &.{}, .lengths = &.{}, .values = &.{} };
                _ = ba.calcMask(&e.bit_alloc, &b.band_psd[ch], start, end, ba.fast_gain_tab[e.fast_gain_code[ch]], is_lfe, none, &b.mask[ch]);
            }
        }
    }

    /// bit_alloc: the allocation for an SNR offset (0 to 1023) into the
    /// current bap buffer, and the mantissas' bits.
    fn bitAlloc(e: *Encoder, snr_offset_in: i32) i32 {
        const snr_offset = (snr_offset_in - 240) * 4;
        const buf = &e.bap[e.cur_bap];
        for (&e.blocks, 0..) |*b, blk| {
            for (@as(usize, @intFromBool(!b.cpl_in_use))..@as(usize, e.channels) + 1) |ch| {
                if (e.exp_strategy[ch][blk] == exp_reuse) continue;
                ba.calcBap(&b.mask[ch], &b.psd[ch], @intCast(e.start_freq[ch]), @intCast(b.end_freq[ch]), snr_offset, e.bit_alloc.floor, &ba.bap_tab, &buf[ch][blk]);
            }
        }
        return e.countMantissaBits();
    }

    /// count_mantissa_bits: each block's mantissas by bap, the grouped
    /// ones padded to whole groups (ac3_compute_mantissa_size_c).
    fn countMantissaBits(e: *const Encoder) i32 {
        var mant_cnt: [num_blocks][16]u16 = @splat(@splat(0));
        for (&mant_cnt) |*c| {
            c[1] = 2;
            c[2] = 2;
            c[4] = 1;
        }
        const max_end_freq: i32 = @as(i32, e.bandwidth_code) * 3 + 73;
        const buf = &e.bap[e.cur_bap];
        for (@as(usize, @intFromBool(!e.cpl_enabled))..@as(usize, e.channels) + 1) |ch| {
            const start = e.start_freq[ch];
            for (&e.blocks, 0..) |*b, blk| {
                if (ch == cpl_ch and !b.cpl_in_use) continue;
                const len = @min(max_end_freq, b.end_freq[ch]) - start;
                if (len <= 0) continue;
                const bap = buf[ch][e.exp_ref_block[ch][blk]][@intCast(start)..][0..@intCast(len)];
                for (bap) |v| mant_cnt[blk][v] +%= 1;
            }
        }
        var total: i32 = 0;
        for (mant_cnt) |c| {
            total += @as(i32, c[1] / 3) * 5;
            total += (@as(i32, c[2] / 3) + (c[4] >> 1)) * 7;
            total += @as(i32, c[3]) * 3;
            for (5..16) |b| total += @as(i32, c[b]) * bap_bits[b];
        }
        return total;
    }

    /// ac3_compute_bit_allocation and cbr_bit_allocation: the largest SNR
    /// offset whose mantissas fit.
    fn computeBitAllocation(e: *Encoder) FrameError!void {
        e.countFrameBits();
        e.exponent_bits = e.countExponentBits();
        e.bitAllocMasking();

        const bits_left = 8 * e.frame_size - (e.frame_bits + e.exponent_bits);
        if (bits_left < 0) return error.BitAllocationFailed;
        var snr_offset = e.coarse_snr_offset << 4;
        // At 1023 last frame, try 1023 first.
        if ((snr_offset | e.fine_snr_offset[1]) == 1023) {
            if (e.bitAlloc(1023) <= bits_left) return;
        }
        while (snr_offset >= 0 and e.bitAlloc(snr_offset) > bits_left) snr_offset -= 64;
        if (snr_offset < 0) return error.BitAllocationFailed;

        e.cur_bap ^= 1;
        var snr_incr: i32 = 64;
        while (snr_incr > 0) : (snr_incr >>= 2) {
            while (snr_offset + snr_incr <= 1023 and e.bitAlloc(snr_offset + snr_incr) <= bits_left) {
                snr_offset += snr_incr;
                e.cur_bap ^= 1;
            }
        }
        e.cur_bap ^= 1;

        e.coarse_snr_offset = snr_offset >> 4;
        for (@as(usize, @intFromBool(!e.cpl_on))..@as(usize, e.channels) + 1) |ch| e.fine_snr_offset[ch] = snr_offset & 0xF;
    }

    /// quantize_mantissas_blk_ch. A quantized value of a huge coefficient
    /// (see symQuant) makes the groups' int products wrap, as the
    /// reference build's do.
    fn quantizeBlkCh(m: *Mant, fixed: []const i32, exp: []const u8, bap: []const u8, qmant: []i16, start: usize, end: usize) void {
        for (start..end) |i| {
            const c = fixed[i];
            const ex = exp[i];
            var v: i32 = bap[i];
            switch (bap[i]) {
                0 => {},
                1 => {
                    v = symQuant(c, ex, 3);
                    switch (m.mant1_cnt) {
                        0 => {
                            m.qmant1 = &qmant[i];
                            v = 9 *% v;
                            m.mant1_cnt = 1;
                        },
                        1 => {
                            m.qmant1.?.* +%= @truncate(3 *% v);
                            m.mant1_cnt = 2;
                            v = 128;
                        },
                        else => {
                            m.qmant1.?.* +%= @truncate(v);
                            m.mant1_cnt = 0;
                            v = 128;
                        },
                    }
                },
                2 => {
                    v = symQuant(c, ex, 5);
                    switch (m.mant2_cnt) {
                        0 => {
                            m.qmant2 = &qmant[i];
                            v = 25 *% v;
                            m.mant2_cnt = 1;
                        },
                        1 => {
                            m.qmant2.?.* +%= @truncate(5 *% v);
                            m.mant2_cnt = 2;
                            v = 128;
                        },
                        else => {
                            m.qmant2.?.* +%= @truncate(v);
                            m.mant2_cnt = 0;
                            v = 128;
                        },
                    }
                },
                3 => v = symQuant(c, ex, 7),
                4 => {
                    v = symQuant(c, ex, 11);
                    switch (m.mant4_cnt) {
                        0 => {
                            m.qmant4 = &qmant[i];
                            v = 11 *% v;
                            m.mant4_cnt = 1;
                        },
                        1 => {
                            m.qmant4.?.* +%= @truncate(v);
                            m.mant4_cnt = 0;
                            v = 128;
                        },
                    }
                },
                5 => v = symQuant(c, ex, 15),
                14 => v = asymQuant(c, ex, 14),
                15 => v = asymQuant(c, ex, 16),
                else => |b| v = asymQuant(c, ex, @intCast(b - 1)),
            }
            qmant[i] = @truncate(v);
        }
    }

    /// ac3_quantize_mantissas: per block, the channels in order with the
    /// coupling channel after the first coupled one.
    fn quantizeMantissas(e: *Encoder) void {
        const buf = &e.bap[e.cur_bap];
        for (&e.blocks, 0..) |*b, blk| {
            var m: Mant = .{};
            var got_cpl = !b.cpl_in_use;
            var ch: usize = 1;
            var ch0: usize = 0;
            while (ch <= e.channels) : (ch += 1) {
                if (!got_cpl and ch > 1 and b.channel_in_cpl[ch - 1]) {
                    ch0 = ch - 1;
                    ch = cpl_ch;
                    got_cpl = true;
                }
                const ref = e.exp_ref_block[ch][blk];
                quantizeBlkCh(&m, &e.fixed_coef[ch][blk], &e.exp[ch][ref], &buf[ch][ref], &b.qmant[ch], @intCast(e.start_freq[ch]), @intCast(b.end_freq[ch]));
                if (ch == cpl_ch) ch = ch0;
            }
        }
    }

    /// ac3_output_frame_header.
    fn outputFrameHeader(e: *const Encoder, w: *bits.BitWriter) void {
        const opt = &e.opt;
        w.bits(16, 0x0b77);
        w.bits(16, 0); // crc1, filled in later
        w.bits(2, e.sr_code);
        w.bits(6, @intCast(@as(i32, e.frame_size_code) + @divTrunc(e.frame_size - e.frame_size_min, 2)));
        w.bits(5, e.bitstream_id);
        w.bits(3, e.bitstream_mode);
        w.bits(3, e.channel_mode);
        if ((e.channel_mode & 1) != 0 and e.channel_mode != ac3.ChannelMode.mono) w.bits(2, e.center_mix_level);
        if ((e.channel_mode & 4) != 0) w.bits(2, e.surround_mix_level);
        if (e.channel_mode == ac3.ChannelMode.stereo) w.bits(2, @intCast(opt.dsur_mode));
        w.bits(1, @intFromBool(e.lfe_on));
        w.bits(5, @intCast(-opt.dialnorm));
        w.bits(1, 0); // no compression control word
        w.bits(1, 0); // no language code
        w.bits(1, @intFromBool(e.audio_production_info));
        if (e.audio_production_info) {
            w.bits(5, @intCast(opt.mixing_level - 80));
            w.bits(2, @intCast(opt.room_type));
        }
        w.bits(1, @intCast(opt.copyright));
        w.bits(1, @intCast(opt.original));
        if (e.bitstream_id == 6) {
            // The alternate bit stream syntax.
            w.bits(1, @intFromBool(e.extended_bsi_1));
            if (e.extended_bsi_1) {
                w.bits(2, @intCast(opt.dmix_mode));
                w.bits(3, e.ltrt_center_mix_level);
                w.bits(3, e.ltrt_surround_mix_level);
                w.bits(3, e.loro_center_mix_level);
                w.bits(3, e.loro_surround_mix_level);
            }
            w.bits(1, @intFromBool(e.extended_bsi_2));
            if (e.extended_bsi_2) {
                w.bits(2, @intCast(opt.dsurex_mode));
                w.bits(2, @intCast(opt.dheadphone_mode));
                w.bits(1, @intCast(opt.ad_conv_type));
                w.bits(9, 0); // xbsi2 and encinfo: reserved
            }
        } else {
            w.bits(1, 0); // no time code 1
            w.bits(1, 0); // no time code 2
        }
        w.bits(1, 0); // no additional bit stream information
    }

    /// output_audio_block.
    fn outputAudioBlock(e: *const Encoder, w: *bits.BitWriter, blk: usize) void {
        const b = &e.blocks[blk];
        const fbw: usize = e.fbw_channels;
        for (0..fbw) |_| w.bits(1, 0); // block switching
        for (0..fbw) |_| w.bits(1, 1); // dither flags
        w.bits(1, 0); // dynamic range codes
        // Channel coupling.
        w.bits(1, @intFromBool(b.new_cpl_strategy));
        if (b.new_cpl_strategy) {
            w.bits(1, @intFromBool(b.cpl_in_use));
            if (b.cpl_in_use) {
                for (1..fbw + 1) |ch| w.bits(1, @intFromBool(b.channel_in_cpl[ch]));
                if (e.channel_mode == ac3.ChannelMode.stereo) w.bits(1, @intFromBool(e.phase_flags_in_use));
                const start_sub: usize = @intCast(@divTrunc(e.start_freq[cpl_ch] - 37, 12));
                const end_sub: usize = @intCast(@divTrunc(e.cpl_end_freq - 37, 12));
                w.bits(4, start_sub);
                w.bits(4, end_sub - 3);
                for (start_sub + 1..end_sub) |bnd| w.bits(1, ba.default_cpl_band_struct[bnd]);
            }
        }
        // Coupling coordinates.
        if (b.cpl_in_use) {
            var cpl_coords_exist = false;
            for (1..fbw + 1) |ch| {
                if (!b.channel_in_cpl[ch]) continue;
                w.bits(1, b.new_cpl_coords[ch]);
                if (b.new_cpl_coords[ch] != 0) {
                    cpl_coords_exist = true;
                    w.bits(2, b.cpl_master_exp[ch]);
                    for (0..e.num_cpl_bands) |bnd| {
                        w.bits(4, b.cpl_coord_exp[ch][bnd]);
                        w.bits(4, b.cpl_coord_mant[ch][bnd]);
                    }
                }
            }
            if (e.channel_mode == ac3.ChannelMode.stereo and e.phase_flags_in_use and cpl_coords_exist) {
                for (0..e.num_cpl_bands) |bnd| w.bits(1, e.phase_flags[bnd]);
            }
        }
        // Stereo rematrixing.
        if (e.channel_mode == ac3.ChannelMode.stereo) {
            w.bits(1, @intFromBool(b.new_rematrixing_strategy));
            if (b.new_rematrixing_strategy) {
                for (0..b.num_rematrixing_bands) |bnd| w.bits(1, b.rematrixing_flags[bnd]);
            }
        }
        // Exponent strategies.
        for (@as(usize, @intFromBool(!b.cpl_in_use))..fbw + 1) |ch| w.bits(2, e.exp_strategy[ch][blk]);
        if (e.lfe_channel) |lfe| w.bits(1, e.exp_strategy[lfe][blk]);
        // Bandwidth.
        for (1..fbw + 1) |ch| {
            if (e.exp_strategy[ch][blk] != exp_reuse and !b.channel_in_cpl[ch]) w.bits(6, e.bandwidth_code);
        }
        // Exponents.
        for (@as(usize, @intFromBool(!b.cpl_in_use))..@as(usize, e.channels) + 1) |ch| {
            const strategy = e.exp_strategy[ch][blk];
            if (strategy == exp_reuse) continue;
            const c: usize = @intFromBool(ch == cpl_ch);
            w.bits(4, b.grouped_exp[ch][0] >> @intCast(c));
            const nb_groups = exponent_group_tab[c][strategy - 1][@intCast(b.end_freq[ch] - e.start_freq[ch])];
            for (1..@as(usize, nb_groups) + 1) |i| w.bits(7, b.grouped_exp[ch][i]);
            const is_lfe = if (e.lfe_channel) |lfe| ch == lfe else false;
            if (!is_lfe and c == 0) w.bits(2, 0); // gain range
        }
        // Bit allocation information.
        const baie = blk == 0;
        w.bits(1, @intFromBool(baie));
        if (baie) {
            w.bits(2, e.slow_decay_code);
            w.bits(2, e.fast_decay_code);
            w.bits(2, e.slow_gain_code);
            w.bits(2, e.db_per_bit_code);
            w.bits(3, e.floor_code);
        }
        // SNR offsets.
        w.bits(1, @intFromBool(b.new_snr_offsets));
        if (b.new_snr_offsets) {
            w.bits(6, @intCast(e.coarse_snr_offset));
            for (@as(usize, @intFromBool(!b.cpl_in_use))..@as(usize, e.channels) + 1) |ch| {
                w.bits(4, @intCast(e.fine_snr_offset[ch]));
                w.bits(3, e.fast_gain_code[ch]);
            }
        }
        // Coupling leak.
        if (b.cpl_in_use) {
            w.bits(1, @intFromBool(b.new_cpl_leak));
            if (b.new_cpl_leak) {
                w.bits(3, @intCast(e.bit_alloc.cpl_fast_leak));
                w.bits(3, @intCast(e.bit_alloc.cpl_slow_leak));
            }
        }
        w.bits(1, 0); // no delta bit allocation
        w.bits(1, 0); // no data to skip
        // Mantissas.
        const buf = &e.bap[e.cur_bap];
        var got_cpl = !b.cpl_in_use;
        var ch: usize = 1;
        var ch0: usize = 0;
        while (ch <= e.channels) : (ch += 1) {
            if (!got_cpl and ch > 1 and b.channel_in_cpl[ch - 1]) {
                ch0 = ch - 1;
                ch = cpl_ch;
                got_cpl = true;
            }
            const bap = &buf[ch][e.exp_ref_block[ch][blk]];
            for (@as(usize, @intCast(e.start_freq[ch]))..@intCast(b.end_freq[ch])) |i| {
                const q: i64 = b.qmant[ch][i];
                // The grouped mantissas go through put_bits, which does not
                // mask the uint16_t a huge coefficient's wrapped value
                // fills; the others through put_sbits, which does.
                const unsigned: u16 = @bitCast(b.qmant[ch][i]);
                switch (bap[i]) {
                    0 => {},
                    1 => if (q != 128) w.bitsUnmasked(5, unsigned),
                    2, 4 => if (q != 128) w.bitsUnmasked(7, unsigned),
                    else => |v| w.signed(@intCast(bap_bits[v]), q),
                }
            }
            if (ch == cpl_ch) ch = ch0;
        }
    }

    /// ac3_output_frame and output_frame_end: zeros to the end, then the
    /// two CRCs (crc1 by the polynomial inverse, as it precedes its data).
    fn outputFrame(e: *const Encoder, frame: []u8) void {
        var w: bits.BitWriter = .init(frame);
        e.outputFrameHeader(&w);
        for (0..num_blocks) |blk| e.outputAudioBlock(&w, blk);
        w.flush();
        std.debug.assert(!w.overflow); // the allocation left room for 18 bits
        @memset(frame[w.pos..], 0);

        const size: usize = frame.len;
        const fs58: usize = ((size >> 2) + (size >> 4)) << 1;
        const crc1_data: u32 = bits.Crc16.hash(frame[4..fs58]);
        const crc_inv = e.crc_inv[@intFromBool(e.frame_size > e.frame_size_min)];
        const crc1: u16 = @truncate(mulPoly(crc_inv, crc1_data, crc16_poly));
        std.mem.writeInt(u16, frame[2..4], crc1, .big);
        var crc2: u16 = bits.Crc16.hash(frame[fs58 .. size - 2]);
        // crc2 must not look like a sync word: flip the crcrsv bit, which
        // xors 0x18005 into the CRC and so leaves it valid.
        if (crc2 == 0x0B77) {
            frame[size - 3] ^= 1;
            crc2 ^= 0x8005;
        }
        std.mem.writeInt(u16, frame[size - 2 ..][0..2], crc2, .big);
    }
};

const testing = std.testing;

const signals = @import("../testing/signals.zig");

/// ac3enc_vectors.c's float sample: the 16-bit signal times the gain over
/// 32768, or a special value.
fn vectorSample(rng: *signals.Rng, signal: []const u8, gain: f32, specials: bool, c: usize, i: usize, state: *[8]i32) f32 {
    const v = signals.sample(rng, signal, c, i, state, 16);
    if (specials) {
        if (i % 397 == 11) return std.math.nan(f32);
        if (i % 401 == 23) return if (c & 1 != 0) -std.math.inf(f32) else std.math.inf(f32);
        if (i % 409 == 37) return 1e30;
    }
    return @as(f32, @floatFromInt(v)) * (gain / 32768.0);
}

/// The options of a vector case: `name=value` pairs joined by `:`, set as
/// av_dict_parse_string and avcodec_open2 set them.
fn vectorOptions(text: []const u8) !Options {
    var o: Options = .{};
    if (std.mem.eql(u8, text, "-")) return o;
    var pairs = std.mem.splitScalar(u8, text, ':');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=').?;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        try options_zig.set(Options, &o, key, value);
    }
    return o;
}

/// ac3enc_vectors.c's output for every case of `vectors`, rendered from
/// the port.
fn renderVectors(gpa: std.mem.Allocator, w: *std.Io.Writer, vectors: []const u8) !void {
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "C ")) continue;
        try w.print("{s}\n", .{line});
        var f = std.mem.tokenizeScalar(u8, line[2..], ' ');
        _ = f.next(); // name
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
        try w.print("O ok\nI {d} {d} {d}\n", .{ e.bitRate(), frame_samples, initial_padding });

        const channels: usize = e.channels;
        var rng: signals.Rng = .{ .state = 0x9E3779B9 ^ @as(u32, @intCast(channels * 1000003 + total)) };
        var state: [8]i32 = @splat(0);
        var planes: [max_channels - 1][frame_samples]f32 = undefined;
        var views: [max_channels - 1][]const f32 = undefined;
        for (&views, &planes) |*v, *p| v.* = p;
        var out: [max_packet]u8 = undefined;
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
            const packet = e.encodeFrame(views[0..channels], n, &out) catch {
                try w.writeAll("E EINVAL\n");
                failed = true;
                break;
            };
            try renderPacket(w, packet.?, &packets, &remaining);
        }
        if (!failed) {
            while (try e.encodeFrame(null, 0, &out)) |packet| try renderPacket(w, packet, &packets, &remaining);
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

test "every case encodes as FFmpeg's AC-3 encoder encodes it (vectors/ac3enc.txt)" {
    const vectors = @embedFile("../testing/vectors/ac3enc.txt");
    var rendered: std.Io.Writer.Allocating = .init(testing.allocator);
    defer rendered.deinit();
    try renderVectors(testing.allocator, &rendered.writer, vectors);
    try testing.expectEqualStrings(vectors, rendered.written());
}

test "the encoder opens and writes frames of its size" {
    var e = try Encoder.init(testing.allocator, 48000, ac3.ch.front_left | ac3.ch.front_right, .{});
    defer e.deinit();
    var left: [frame_samples]f32 = undefined;
    var right: [frame_samples]f32 = undefined;
    for (&left, &right, 0..) |*l, *r, i| {
        const t: f32 = @floatFromInt(i);
        l.* = 0.5 * @sin(t * 0.05);
        r.* = 0.25 * @sin(t * 0.11);
    }
    var out: [max_packet]u8 = undefined;
    const packet = (try e.encodeFrame(&.{ &left, &right }, frame_samples, &out)).?;
    try testing.expectEqual(768, packet.len);
    try testing.expectEqual(0x0b, packet[0]);
    try testing.expectEqual(0x77, packet[1]);
    try testing.expectEqual(192000, e.bitRate());
}

const hostile = @import("../testing/hostile.zig");

/// The fuzz entry's input: raw f32 samples (any bits: NaN, infinities,
/// huge values), then the rate's index, the layout's index, the bit rate,
/// the coupling option, the coupling start band and the cutoff. Every
/// packet must carry an AC-3 header of its own size; the port's decoder
/// then reads it (its result is not checked: only that it returns).
fn fuzzRun(smith: *std.testing.Smith) !u32 {
    var input: [2 * frame_samples * 6 * 4 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const rate = ac3.sample_rate_tab[smith.valueRangeAtMost(u8, 0, 2)];
    const layout = layouts[smith.valueRangeAtMost(u8, 0, layouts.len - 1)];
    var options: Options = .{
        .bit_rate = @bitCast(smith.value(u64)),
        .channel_coupling = smith.valueRangeAtMost(i32, -1, 1),
        .cpl_start_band = smith.valueRangeAtMost(i32, -1, 15),
        .cutoff = smith.value(i32),
    };
    if (options.bit_rate < 0) options.bit_rate = 0;
    const e = Encoder.init(testing.allocator, rate, layout, options) catch |err| switch (err) {
        error.InvalidOption => return 0, // a negative cutoff
        error.UnsupportedFormat => unreachable, // the rates and layouts above
        error.OutOfMemory => return err,
    };
    defer e.deinit();
    var d = try ac3dec.Decoder.init(testing.allocator, rate);
    defer d.deinit();
    const channels: usize = e.channels;
    const frame_bytes = 4 * channels;
    const total = (len - len % frame_bytes) / frame_bytes;
    var planes: [max_channels - 1][frame_samples]f32 = undefined;
    var views: [max_channels - 1][]const f32 = undefined;
    for (&views, &planes) |*v, *p| v.* = p;
    var out: [max_packet]u8 = undefined;
    var packets: u32 = 0;
    var start: usize = 0;
    while (true) {
        const n = @min(total - start, frame_samples);
        const got = if (start < total or packets == 0) blk: {
            for (0..n) |i| {
                for (0..channels) |c| planes[c][i] = @bitCast(std.mem.readInt(u32, input[((start + i) * channels + c) * 4 ..][0..4], .little));
            }
            start += n;
            break :blk e.encodeFrame(views[0..channels], n, &out);
        } else e.encodeFrame(null, 0, &out);
        const packet = (got catch |err| switch (err) {
            error.BitAllocationFailed => return packets,
            error.InvalidFrame => unreachable, // whole planes of at most a frame
        }) orelse break;
        const header = try ac3.parseHeaderShort(packet);
        try testing.expectEqual(packet.len, header.frame_size);
        try testing.expectEqual(rate, header.sample_rate);
        _ = d.decode(packet) catch {};
        packets += 1;
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
const fuzz_corpus: []const []const u8 = &.{
    // The values: the rate's index, the layout's index, the bit rate,
    // coupling, the coupling start band, the cutoff.
    hostile.fuzzSeed(&seed_samples, &.{ 0, 1, 192000, @bitCast(@as(i64, -1)), @bitCast(@as(i64, -1)), 0 }),
    hostile.fuzzSeed(&seed_samples, &.{ 1, 1, 96000, 1, 3, 0 }),
    hostile.fuzzSeed(&seed_samples, &.{ 2, 14, 0, @bitCast(@as(i64, -1)), @bitCast(@as(i64, -1)), 0 }),
    hostile.fuzzSeed(&seed_samples, &.{ 0, 9, 32000, 0, 0, 9000 }),
    hostile.fuzzSeed(&(@as([4 * frame_samples * 2]u8, @splat(0x7f)) ++ @as([4 * frame_samples * 2]u8, @splat(0xff))), &.{ 0, 7, 640000, 1, 15, 0 }),
    hostile.fuzzSeed("", &.{ 1, 0, 64000, 0, 0, 0 }),
};

test "fuzz: the AC-3 encoder on arbitrary samples, layouts and options" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "every seed of the AC-3 encoder's fuzz entry encodes frames" {
    for (fuzz_corpus) |seed| {
        var smith: std.testing.Smith = .{ .in = seed };
        _ = try fuzzRun(&smith);
    }
}

test "mutation smoke: the AC-3 encoder on mutated seeds" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 16, 0x61633365);
}

fn encodeUnderFailures(gpa: std.mem.Allocator, layout: u64) !void {
    const e = try Encoder.init(gpa, 48000, layout, .{});
    defer e.deinit();
    var plane: [frame_samples]f32 = @splat(0.25);
    var views: [6][]const f32 = @splat(&plane);
    var out: [max_packet]u8 = undefined;
    _ = try e.encodeFrame(views[0..e.channels], frame_samples, &out);
}

test "the AC-3 encoder frees everything under every allocation and remap failure" {
    try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.both, @as(u64, ac3.ch.front_left | ac3.ch.front_right), encodeUnderFailures);
}
