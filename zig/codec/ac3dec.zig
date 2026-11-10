// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/ac3dec.c, ac3dec_float.c, ac3dec.h,
// ac3dec_data.c, ac3tab.c and eac3dec.c at the pinned reference revision
// (the bit allocation, from ac3.c and ac3dsp.c, is ac3_bitalloc.zig's).
// Copyright (c) 2007-2008 Bartlomiej Wolowiec <bartek.wolowiec@gmail.com>
// Copyright (c) 2007-2008 Justin Ruggles <justin.ruggles@gmail.com>
// Copyright (c) 2008 Justin Ruggles
// Copyright (c) 2007 Kostya Shishkov
// Copyright (c) 2006 Justin Ruggles
// Copyright (c) 2001-2003 Fabrice Bellard
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's float AC-3 decoder (`ac3`, TODO.md T32a), sample for sample:
//! exponents, bit allocation, mantissas with dither, coupling,
//! rematrixing, dynamic range, the 256- and 128-point IMDCTs and the KBD
//! window, and its error concealment, which repeats a block's output when
//! a frame fails. Its options keep FFmpeg's defaults (no downmix, the
//! dynamic range scale 1, no heavy compression, no target level, no
//! consistent noise): the decoder gives every coded channel in
//! `ff_ac3_channel_layout_tab`'s layout. Since T32b it is also FFmpeg's
//! E-AC-3 decoder (`eac3`): the frame syntax, spectral extension, AHT
//! with gain-adaptive quantization, enhanced bit allocation, and
//! dependent frames with their channel map; reduced sample rates and
//! enhanced coupling fail with PATCHWELCOME as FFmpeg's (notes.md
//! "E-AC-3").

const std = @import("std");
const bits = @import("bits.zig");
const ac3 = @import("ac3.zig");
const tx = @import("tx.zig");
const float_dsp = @import("float_dsp.zig");
const aac_tab = @import("aac_tab.zig");
const Lfg = @import("../core/lfg.zig").Lfg;
const eac3_data = @import("eac3_data.zig");
const bitalloc = @import("ac3_bitalloc.zig");
const bap_tab = bitalloc.bap_tab;
const slow_decay_tab = bitalloc.slow_decay_tab;
const fast_decay_tab = bitalloc.fast_decay_tab;
const slow_gain_tab = bitalloc.slow_gain_tab;
const db_per_bit_tab = bitalloc.db_per_bit_tab;
const floor_tab = bitalloc.floor_tab;
const fast_gain_tab = bitalloc.fast_gain_tab;
const rematrix_band_tab = bitalloc.rematrix_band_tab;
const default_cpl_band_struct = bitalloc.default_cpl_band_struct;
pub const band_start_tab = bitalloc.band_start_tab;
pub const bin_to_band_tab = bitalloc.bin_to_band_tab;
const BitAllocParams = bitalloc.BitAllocParams;
const Dba = bitalloc.Dba;
const calcPsd = bitalloc.calcPsd;
const calcMask = bitalloc.calcMask;
const calcBap = bitalloc.calcBap;

pub const max_channels = 7; // AC3_MAX_CHANNELS, the coupling channel included
const cpl_ch = 0;
const max_coefs = bitalloc.max_coefs;
pub const block_size = 256;
const max_blocks = 6;
const critical_bands = bitalloc.critical_bands;
const max_cpl_bands = 18;
/// AC3_FRAME_BUFFER_SIZE.
const frame_buffer_size = 32768;
const output_lfeon = 8;

const exp_reuse = 0;
const exp_d45 = 3;
const dba_new = bitalloc.dba_new;
const dba_none = 2;
const dba_reserved = 3;

// --- Tables -----------------------------------------------------------------

/// 2^v, exactly, for the dynamic range tables' `powf(2.0f, v)`.
fn exp2i(v: i32) f32 {
    return if (v >= 0) @floatFromInt(@as(u32, 1) << v) else 1.0 / @as(f32, @floatFromInt(@as(u32, 1) << -v));
}

/// `dynamic_range_tab`: code to scale factor (7.7.1).
const dynamic_range_tab: [256]f32 = blk: {
    var t: [256]f32 = undefined;
    for (&t, 0..) |*x, i| {
        const v: i32 = @as(i32, i >> 5) - @as(i32, (i >> 7) << 3) - 5;
        x.* = exp2i(v) * @as(f32, @floatFromInt((i & 0x1F) | 0x20));
    }
    break :blk t;
};

/// `scale_factors`: 2^-exp.
const scale_factors: [25]f32 = blk: {
    var t: [25]f32 = undefined;
    for (&t, 0..) |*x, i| x.* = exp2i(-@as(i32, i));
    break :blk t;
};

/// SYMMETRIC_DEQUANT, with C's truncating division.
fn symmetricDequant(code: i32, levels: i32) i32 {
    return @divTrunc((code - (levels >> 1)) * (1 << 24), levels);
}

const ungroup_3_in_7: [128][3]u8 = blk: {
    var t: [128][3]u8 = undefined;
    for (&t, 0..) |*x, i| x.* = .{ i / 25, (i % 25) / 5, (i % 25) % 5 };
    break :blk t;
};

const ungroup_3_in_5: [32][3]u8 = blk: {
    var t: [32][3]u8 = undefined;
    for (&t, 0..) |*x, i| x.* = .{ i / 9, (i % 9) / 3, (i % 9) % 3 };
    break :blk t;
};

const bap1_mantissas: [32][3]i32 = blk: {
    var t: [32][3]i32 = undefined;
    for (&t, ungroup_3_in_5) |*x, g| {
        for (x, g) |*m, c| m.* = symmetricDequant(c, 3);
    }
    break :blk t;
};

const bap2_mantissas: [128][3]i32 = blk: {
    var t: [128][3]i32 = undefined;
    for (&t, ungroup_3_in_7) |*x, g| {
        for (x, g) |*m, c| m.* = symmetricDequant(c, 5);
    }
    break :blk t;
};

const bap4_mantissas: [128][2]i32 = blk: {
    var t: [128][2]i32 = undefined;
    for (&t, 0..) |*x, i| x.* = .{ symmetricDequant(i / 11, 11), symmetricDequant(i % 11, 11) };
    break :blk t;
};

/// `ff_ac3_bap3_mantissas`: seven levels, then 0.
const bap3_mantissas: [8]i32 = blk: {
    var t: [8]i32 = @splat(0);
    for (0..7) |i| t[i] = symmetricDequant(i, 7);
    break :blk t;
};

const bap5_mantissas: [16]i32 = blk: {
    var t: [16]i32 = @splat(0);
    for (0..15) |i| t[i] = symmetricDequant(i, 15);
    break :blk t;
};

const quantization_tab = [16]u8{ 0, 3, 5, 7, 11, 15, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16 };

/// `ff_ac3_dec_channel_map`: by channel mode and LFE, each output channel's
/// coded channel.
const dec_channel_map = [8][2][6]u8{
    .{ .{ 0, 1, 0, 0, 0, 0 }, .{ 0, 1, 2, 0, 0, 0 } },
    .{ .{ 0, 0, 0, 0, 0, 0 }, .{ 0, 1, 0, 0, 0, 0 } },
    .{ .{ 0, 1, 0, 0, 0, 0 }, .{ 0, 1, 2, 0, 0, 0 } },
    .{ .{ 0, 2, 1, 0, 0, 0 }, .{ 0, 2, 1, 3, 0, 0 } },
    .{ .{ 0, 1, 2, 0, 0, 0 }, .{ 0, 1, 3, 2, 0, 0 } },
    .{ .{ 0, 2, 1, 3, 0, 0 }, .{ 0, 2, 1, 4, 3, 0 } },
    .{ .{ 0, 1, 2, 3, 0, 0 }, .{ 0, 1, 4, 2, 3, 0 } },
    .{ .{ 0, 2, 1, 3, 4, 0 }, .{ 0, 2, 1, 5, 3, 4 } },
};

/// The decoder's KBD window, alpha 5 over 256 samples.
const window: [256]f32 = aac_tab.kbdWindow(256, 5.0);

// --- The decoder --------------------------------------------------------------

/// EAC3_MAX_CHANNELS: the output buffers, a dependent frame's channels
/// after the independent frame's (`AC3_MAX_CHANNELS` apart).
pub const max_out_channels = 16;

/// A decode call's failure, as FFmpeg's return code names it.
pub const Error = error{
    /// AVERROR_INVALIDDATA.
    InvalidData,
    /// AVERROR_PATCHWELCOME: an E-AC-3 frame at a reduced sample rate.
    PatchWelcome,
    /// An AC3_PARSE_ERROR_* code, which ac3_decode_frame returns as it is
    /// when the header after a frame does not parse (`errorCode`).
    NextSync,
    NextBsid,
    NextSampleRate,
    NextFrameSize,
    NextFrameType,
    NextChannelMap,
};

/// The int ac3_decode_frame returns for `err`, as libavcodec passes it on.
pub fn errorCode(err: Error) i32 {
    return switch (err) {
        error.InvalidData => -0x41444e49, // AVERROR_INVALIDDATA
        error.PatchWelcome => -0x45574150, // AVERROR_PATCHWELCOME
        error.NextSync => -0x1030c0a,
        error.NextBsid => -0x2030c0a,
        error.NextSampleRate => -0x3030c0a,
        error.NextFrameSize => -0x4030c0a,
        error.NextFrameType => -0x5030c0a,
        error.NextChannelMap => -0x7030c0a,
    };
}

/// Where an output "pointer" (`output[]`, `outptr[]`) points: a channel's
/// last block (`s->output`) or a place in the frame's buffer.
const Ptr = struct { frame: bool, ch: u8, off: u16 };

const spx_max_bands = 17;
const default_spx_band_struct = [spx_max_bands]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 };

/// ff_eac3_hebap_tab.
const hebap_tab = [64]u8{
    0,  1,  2,  3,  4,  5,  6,  7,  8,  8,  8,  8,  9,  9,  9,  10,
    10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 12, 13, 13, 13, 13, 14,
    14, 14, 14, 15, 15, 15, 15, 16, 16, 16, 16, 17, 17, 17, 17, 18,
    18, 18, 18, 18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 19, 19, 19,
};

/// ff_eac3_gain_levels_lfe.
const gain_levels_lfe = [32]f32{
    3.162275, 2.818382, 2.511886, 2.238719, 1.995261, 1.778278, 1.584893, 1.412536,
    1.258924, 1.122018, 1.000000, 0.891251, 0.794328, 0.707946, 0.630957, 0.562341,
    0.501187, 0.446683, 0.398107, 0.354813, 0.316227, 0.281838, 0.251188, 0.223872,
    0.199526, 0.177828, 0.158489, 0.141253, 0.125892, 0.112201, 0.100000, 0.089125,
};

/// The flushable part of `AC3DecodeContext`, zeroed at the start (FFmpeg's
/// zeroed private data).
const State = struct {
    frame_type: u8 = 0,
    substreamid: i32 = 0,
    superframe_size: u32 = 0,
    frame_size: u32 = 0,
    sample_rate: u32 = 0,
    bit_rate: u32 = 0,
    num_blocks: u32 = 0,
    bitstream_id: u8 = 0,
    bitstream_mode: u8 = 0,
    channel_mode: u8 = 0,
    lfe_on: u8 = 0,
    channel_map: u16 = 0,
    preferred_downmix: u8 = 0,
    center_mix_level: i32 = 0,
    center_mix_level_ltrt: i32 = 0,
    surround_mix_level: i32 = 0,
    surround_mix_level_ltrt: i32 = 0,
    lfe_mix_level_exists: bool = false,
    lfe_mix_level: u8 = 0,
    eac3: bool = false,
    eac3_subsbtreamid_found: bool = false,
    dolby_surround_mode: i32 = 0,
    snr_offset_strategy: u8 = 0,
    block_switch_syntax: bool = false,
    dither_flag_syntax: bool = false,
    bit_allocation_syntax: bool = false,
    fast_gain_syntax: bool = false,
    dba_syntax: bool = false,
    skip_syntax: bool = false,

    cpl_in_use: [max_blocks]bool = @splat(false),
    cpl_strategy_exists: [max_blocks]bool = @splat(false),
    channel_in_cpl: [max_channels]bool = @splat(false),
    phase_flags_in_use: bool = false,
    phase_flags: [max_cpl_bands]bool = @splat(false),
    num_cpl_bands: usize = 0,
    cpl_band_struct: [max_cpl_bands]u8 = @splat(0),
    cpl_band_sizes: [max_cpl_bands]u8 = @splat(0),
    first_cpl_coords: [max_channels]bool = @splat(false),
    cpl_coords: [max_channels][max_cpl_bands]i32 = @splat(@splat(0)),

    spx_in_use: bool = false,
    channel_uses_spx: [max_channels]bool = @splat(false),
    spx_atten_code: [max_channels]i8 = @splat(0),
    spx_src_start_freq: usize = 0,
    spx_dst_end_freq: usize = 0,
    spx_dst_start_freq: usize = 0,
    num_spx_bands: usize = 0,
    spx_band_struct: [spx_max_bands]u8 = @splat(0),
    spx_band_sizes: [spx_max_bands]u8 = @splat(0),
    first_spx_coords: [max_channels]bool = @splat(false),
    spx_noise_blend: [max_channels][spx_max_bands]f32 = @splat(@splat(0)),
    spx_signal_blend: [max_channels][spx_max_bands]f32 = @splat(@splat(0)),

    channel_uses_aht: [max_channels]bool = @splat(false),
    pre_mantissa: [max_channels][max_coefs][max_blocks]i32 = @splat(@splat(@splat(0))),

    fbw_channels: u8 = 0,
    channels: u8 = 0,
    lfe_ch: u8 = 0,
    /// Starts set: FFmpeg's init sets `downmixed` after the zeroed
    /// context, and a flush (not modeled) would clear it.
    downmixed: bool = true,
    output_mode: u8 = 0,
    prev_output_mode: u8 = 0,
    out_channels: u8 = 0,
    prev_bit_rate: u32 = 0,

    dynamic_range: [2]f32 = .{ 0, 0 },
    start_freq: [max_channels]usize = @splat(0),
    end_freq: [max_channels]usize = @splat(0),
    num_rematrixing_bands: usize = 0,
    rematrixing_flags: [4]bool = @splat(false),
    num_exp_groups: [max_channels]usize = @splat(0),
    dexps: [max_channels][max_coefs]i8 = @splat(@splat(0)),
    exp_strategy: [max_blocks][max_channels]u8 = @splat(@splat(0)),
    bit_alloc_params: BitAllocParams = .{},
    first_cpl_leak: bool = false,
    snr_offset: [max_channels]i32 = @splat(0),
    fast_gain: [max_channels]i32 = @splat(0),
    bap: [max_channels][max_coefs]u8 = @splat(@splat(0)),
    psd: [max_channels][max_coefs]i16 = @splat(@splat(0)),
    band_psd: [max_channels][critical_bands]i16 = @splat(@splat(0)),
    mask: [max_channels][critical_bands]i16 = @splat(@splat(0)),
    dba_mode: [max_channels]i32 = @splat(0),
    dba_nsegs: [max_channels]i32 = @splat(0),
    dba_offsets: [max_channels][8]u8 = @splat(@splat(0)),
    dba_lengths: [max_channels][8]u8 = @splat(@splat(0)),
    dba_values: [max_channels][8]u8 = @splat(@splat(0)),
    dither_flag: [max_channels]bool = @splat(false),
    block_switch: [max_channels]bool = @splat(false),

    coeffs: [max_channels][max_coefs]f32 = @splat(@splat(0)),
    transform_coeffs: [max_channels][max_coefs]f32 = @splat(@splat(0)),
    delay: [max_out_channels][block_size]f32 = @splat(@splat(0)),
    tmp_output: [block_size]f32 = @splat(0),
    /// `s->output`: each output channel's last block, for concealment.
    output: [max_out_channels][block_size]f32 = @splat(@splat(0)),
    /// `s->output_buffer`: the frame's samples, by output channel.
    output_buffer: [max_out_channels][block_size * max_blocks]f32 = @splat(@splat(0)),
    outptr: [max_channels]Ptr = undefined,
};

/// What a call gives: the bytes consumed and, when it made one, a frame.
pub const Decoded = struct {
    consumed: usize,
    frame: ?Frame,
};

/// A decoded frame: planar float samples, valid until the next call.
pub const Frame = struct {
    planes: [max_out_channels][]const f32,
    channels: u8,
    /// The output's channel mask: ff_ac3_channel_layout_tab with the LFE,
    /// or a dependent frame's custom channels added.
    channel_layout: u64,
    samples: u32,
    sample_rate: u32,
    /// `decode_error_flags`: the frame repeats concealed blocks.
    concealed: bool,
    /// The AVDownmixInfo side data, for a stream coded with more than two
    /// channels.
    downmix: ?Downmix,
};

/// AVDownmixInfo's fields, as the decoder fills them.
pub const Downmix = struct {
    /// AC3_DMIXMOD_*: not indicated (0), Lt/Rt (1), Lo/Ro (2), Dolby Pro
    /// Logic II (3).
    preferred: u8,
    center_mix_level: f64,
    center_mix_level_ltrt: f64,
    surround_mix_level: f64,
    surround_mix_level_ltrt: f64,
    lfe_mix_level: f64,
};

/// `ff_ac3_gain_levels`, a float table.
pub const gain_levels = [9]f32{
    std.math.sqrt2,     1.1892071150027209, 1.0, 0.8408964152537145, std.math.sqrt1_2,
    0.5946035575013605, 0.5,                0.0, 0.3535533905932738,
};

/// idct6 on AHT's pre-mantissas, in the C's int64 products and int
/// stores. Its int sums overflow on hostile mantissas, which wraps in the
/// reference build, so they wrap here (notes.md "E-AC-3", "AHT's integer
/// arithmetic").
fn idct6(m: *[6]i32) void {
    const c0: i64 = 10273905;
    const c1: i64 = 11863283;
    const c2: i64 = 3070444;
    const odd1 = m[1] -% m[3] -% m[5];
    var even2: i32 = @truncate((@as(i64, m[2]) * c0) >> 23);
    var tmp: i32 = @truncate((@as(i64, m[4]) * c1) >> 23);
    var odd0: i32 = @truncate((@as(i64, m[1] +% m[5]) * c2) >> 23);
    var even0 = m[0] +% (tmp >> 1);
    const even1 = m[0] -% tmp;
    tmp = even0;
    even0 = tmp +% even2;
    even2 = tmp -% even2;
    tmp = odd0;
    odd0 = tmp +% m[1] +% m[3];
    const odd2 = tmp +% m[5] -% m[3];
    m[0] = even0 +% odd0;
    m[1] = even1 +% odd1;
    m[2] = even2 +% odd2;
    m[3] = even2 -% odd2;
    m[4] = even1 -% odd1;
    m[5] = even0 -% odd0;
}

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    mdct128: tx.Mdct,
    mdct256: tx.Mdct,
    dith_state: Lfg,
    /// `avctx->sample_rate`: the stream's (the parser's), then each good
    /// frame's.
    sample_rate: u32,
    /// `avctx->bit_rate` as each good frame sets it (`bit_rate` plus the
    /// last dependent frame's); null before one.
    bit_rate: ?u32 = null,
    /// `avctx->ch_layout`'s mask as the decoder last set it, 0 before:
    /// each frame that reaches its blocks sets it, before anything that
    /// can still fail the packet (the look for a dependent frame), so a
    /// failed packet can leave it set where the rate and bit rate are not
    /// (the read-ahead takes it either way, as FFmpeg's try_decode_frame).
    ch_layout: u64 = 0,
    s: *State,
    /// `input_buffer`, kept across calls as FFmpeg's is (a byte-swapped
    /// frame of odd length leaves the last byte from before).
    input: *[frame_buffer_size + 64]u8,

    /// ac3_decode_init for a stream the demuxer gave `sample_rate` (0 when
    /// none).
    pub fn init(gpa: std.mem.Allocator, sample_rate: u32) error{OutOfMemory}!Decoder {
        var m128 = tx.Mdct.init(gpa, 128, true, 1.0) catch return error.OutOfMemory;
        errdefer m128.deinit();
        var m256 = tx.Mdct.init(gpa, 256, true, 1.0) catch return error.OutOfMemory;
        errdefer m256.deinit();
        const s = try gpa.create(State);
        errdefer gpa.destroy(s);
        s.* = .{};
        const input = try gpa.create([frame_buffer_size + 64]u8);
        @memset(input, 0);
        return .{ .gpa = gpa, .mdct128 = m128, .mdct256 = m256, .dith_state = .init(0), .sample_rate = sample_rate, .s = s, .input = input };
    }

    pub fn deinit(d: *Decoder) void {
        d.mdct128.deinit();
        d.mdct256.deinit();
        d.gpa.destroy(d.s);
        d.gpa.destroy(d.input);
        d.* = undefined;
    }

    fn slice(d: *Decoder, p: Ptr) []f32 {
        return if (p.frame) d.s.output_buffer[p.ch][p.off..] else d.s.output[p.ch][p.off..];
    }

    /// parse_frame_header; null on success.
    fn parseFrameHeader(d: *Decoder, r: *bits.BitReader) ?anyerror {
        const s = d.s;
        const hdr = ac3.parseHeader(r) catch |err| return err;
        s.bit_alloc_params.sr_code = hdr.sr_code;
        s.bitstream_id = hdr.bitstream_id;
        s.bitstream_mode = hdr.bitstream_mode;
        s.channel_mode = hdr.channel_mode;
        s.lfe_on = hdr.lfe_on;
        s.bit_alloc_params.sr_shift = hdr.sr_shift;
        s.sample_rate = hdr.sample_rate;
        s.bit_rate = hdr.bit_rate;
        s.channels = hdr.channels;
        s.fbw_channels = s.channels - s.lfe_on;
        s.lfe_ch = s.fbw_channels + 1;
        s.frame_size = hdr.frame_size;
        s.superframe_size += hdr.frame_size;
        s.preferred_downmix = 0; // AC3_DMIXMOD_NOTINDICATED
        if (hdr.bitstream_id <= 10) {
            s.center_mix_level = hdr.center_mix_level;
            s.surround_mix_level = hdr.surround_mix_level;
        }
        s.center_mix_level_ltrt = 4; // -3.0 dB
        s.surround_mix_level_ltrt = 4;
        s.lfe_mix_level_exists = false;
        s.num_blocks = @intCast(hdr.num_blocks);
        s.frame_type = hdr.frame_type;
        s.substreamid = hdr.substreamid;
        s.dolby_surround_mode = hdr.dolby_surround_mode;
        if (s.lfe_on != 0) {
            s.start_freq[s.lfe_ch] = 0;
            s.end_freq[s.lfe_ch] = 7;
            s.num_exp_groups[s.lfe_ch] = 2;
            s.channel_in_cpl[s.lfe_ch] = false;
        }
        if (s.bitstream_id <= 10) {
            s.eac3 = false;
            s.snr_offset_strategy = 2;
            s.block_switch_syntax = true;
            s.dither_flag_syntax = true;
            s.bit_allocation_syntax = true;
            s.fast_gain_syntax = false;
            s.first_cpl_leak = false;
            s.dba_syntax = true;
            s.skip_syntax = true;
            s.channel_uses_aht = @splat(false);
            // The dialog normalization and heavy compression values only
            // serve the target_level and heavy_compr options, off.
            return null;
        }
        s.eac3 = true;
        return d.eac3ParseHeader(r, &hdr);
    }

    /// ff_eac3_parse_header: the frame-level syntax after the header.
    fn eac3ParseHeader(d: *Decoder, r: *bits.BitReader, hdr: *const ac3.HeaderInfo) ?anyerror {
        const s = d.s;
        // ff_ac3_parse_header refuses a reserved frame type and other
        // substreams before here.
        if (s.frame_type == ac3.FrameType.reserved or s.substreamid != 0) return error.FrameType;
        if (s.bit_alloc_params.sr_code == 3) return error.PatchWelcome; // "Reduced sampling rate"
        s.channel_map = hdr.channel_map;
        s.preferred_downmix = hdr.preferred_downmix;
        s.center_mix_level_ltrt = hdr.center_mix_level_ltrt;
        s.center_mix_level = hdr.center_mix_level;
        s.surround_mix_level_ltrt = hdr.surround_mix_level_ltrt;
        s.surround_mix_level = hdr.surround_mix_level;
        s.lfe_mix_level_exists = hdr.lfe_mix_level_exists != 0;
        s.lfe_mix_level = hdr.lfe_mix_level;
        s.dolby_surround_mode = hdr.dolby_surround_mode;
        s.bitstream_mode = hdr.bitstream_mode;
        var ac3_exponent_strategy = true;
        var parse_aht_info = false;
        if (s.num_blocks == 6) {
            ac3_exponent_strategy = r.bit() != 0;
            parse_aht_info = r.bit() != 0;
        }
        s.snr_offset_strategy = @intCast(r.bits(2));
        const parse_transient_proc_info = r.bit() != 0;
        s.block_switch_syntax = r.bit() != 0;
        if (!s.block_switch_syntax) s.block_switch = @splat(false);
        s.dither_flag_syntax = r.bit() != 0;
        if (!s.dither_flag_syntax) {
            for (1..@as(usize, s.fbw_channels) + 1) |ch| s.dither_flag[ch] = true;
        }
        s.dither_flag[cpl_ch] = false;
        s.dither_flag[s.lfe_ch] = false;
        s.bit_allocation_syntax = r.bit() != 0;
        if (!s.bit_allocation_syntax) {
            s.bit_alloc_params.slow_decay = slow_decay_tab[2];
            s.bit_alloc_params.fast_decay = fast_decay_tab[1];
            s.bit_alloc_params.slow_gain = slow_gain_tab[1];
            s.bit_alloc_params.db_per_bit = db_per_bit_tab[2];
            s.bit_alloc_params.floor = floor_tab[7];
        }
        s.fast_gain_syntax = r.bit() != 0;
        s.dba_syntax = r.bit() != 0;
        s.skip_syntax = r.bit() != 0;
        const parse_spx_atten_data = r.bit() != 0;
        // Coupling strategy occurrence and use per block.
        var num_cpl_blocks: usize = 0;
        if (s.channel_mode > 1) {
            for (0..s.num_blocks) |blk| {
                s.cpl_strategy_exists[blk] = blk == 0 or r.bit() != 0;
                s.cpl_in_use[blk] = if (s.cpl_strategy_exists[blk]) r.bit() != 0 else s.cpl_in_use[blk - 1];
                num_cpl_blocks += @intFromBool(s.cpl_in_use[blk]);
            }
        } else s.cpl_in_use = @splat(false);
        // Exponent strategies.
        if (ac3_exponent_strategy) {
            for (0..s.num_blocks) |blk| {
                for (@intFromBool(!s.cpl_in_use[blk])..@as(usize, s.fbw_channels) + 1) |ch| s.exp_strategy[blk][ch] = @intCast(r.bits(2));
            }
        } else {
            const first: usize = @intFromBool(!(s.channel_mode > 1 and num_cpl_blocks != 0));
            for (first..@as(usize, s.fbw_channels) + 1) |ch| {
                const frmchexpstr = r.bits(5);
                for (0..6) |blk| s.exp_strategy[blk][ch] = eac3_data.frm_expstr[frmchexpstr][blk];
            }
        }
        if (s.lfe_on != 0) {
            for (0..s.num_blocks) |blk| s.exp_strategy[blk][s.lfe_ch] = r.bit();
        }
        // A converter's original exponent strategies.
        if (s.frame_type == ac3.FrameType.independent and (s.num_blocks == 6 or r.bit() != 0)) r.skip(5 * @as(usize, s.fbw_channels));
        // Which channels use AHT: every later block reuses the first's
        // exponents, and for coupling every block couples with one strategy.
        if (parse_aht_info) {
            s.channel_uses_aht[cpl_ch] = false;
            for (@intFromBool(num_cpl_blocks != 6)..@as(usize, s.channels) + 1) |ch| {
                var use_aht = true;
                for (1..6) |blk| {
                    if (s.exp_strategy[blk][ch] != exp_reuse or (ch == 0 and s.cpl_strategy_exists[blk])) {
                        use_aht = false;
                        break;
                    }
                }
                s.channel_uses_aht[ch] = use_aht and r.bit() != 0;
            }
        } else s.channel_uses_aht = @splat(false);
        // The frame's SNR offset.
        if (s.snr_offset_strategy == 0) {
            const csnroffst: i32 = (@as(i32, @intCast(r.bits(6))) - 15) << 4;
            const snroffst: i32 = (csnroffst + @as(i32, @intCast(r.bits(4)))) << 2;
            for (0..@as(usize, s.channels) + 1) |ch| s.snr_offset[ch] = snroffst;
        }
        // Transient pre-noise processing.
        if (parse_transient_proc_info) {
            for (1..@as(usize, s.fbw_channels) + 1) |_| {
                if (r.bit() != 0) r.skip(18);
            }
        }
        // Spectral extension attenuation.
        for (1..@as(usize, s.fbw_channels) + 1) |ch| {
            s.spx_atten_code[ch] = if (parse_spx_atten_data and r.bit() != 0) @intCast(r.bits(5)) else -1;
        }
        // Block start information.
        if (s.num_blocks > 1 and r.bit() != 0) {
            const frame_bits: u32 = s.frame_size - 2;
            const log2: i64 = 31 - @as(i64, @clz(frame_bits | 1));
            r.skipLong(@as(i64, s.num_blocks - 1) * (4 + log2));
        }
        for (1..@as(usize, s.fbw_channels) + 1) |ch| {
            s.first_spx_coords[ch] = true;
            s.first_cpl_coords[ch] = true;
        }
        s.first_cpl_leak = true;
        return null;
    }

    /// decode_exponents; false on an out-of-range group or exponent.
    fn decodeExponents(r: *bits.BitReader, exp_strategy: u8, ngrps: usize, absexp: u8, dexps: []i8) bool {
        var dexp: [256]u8 = undefined;
        const group_size: usize = @as(usize, exp_strategy) + @intFromBool(exp_strategy == exp_d45);
        var i: usize = 0;
        for (0..ngrps) |_| {
            const expacc = r.bits(7);
            if (expacc >= 125) return false;
            dexp[i] = ungroup_3_in_7[expacc][0];
            dexp[i + 1] = ungroup_3_in_7[expacc][1];
            dexp[i + 2] = ungroup_3_in_7[expacc][2];
            i += 3;
        }
        var prevexp: i32 = absexp;
        var j: usize = 0;
        for (dexp[0 .. ngrps * 3]) |dx| {
            prevexp += @as(i32, dx) - 2;
            if (prevexp < 0 or prevexp > 24) return false;
            const v: i8 = @intCast(prevexp);
            @memset(dexps[j..][0..group_size], v);
            j += group_size;
        }
        return true;
    }

    fn calcTransformCoeffsCpl(d: *Decoder) void {
        const s = d.s;
        var bin = s.start_freq[cpl_ch];
        for (0..s.num_cpl_bands) |band| {
            const band_start = bin;
            const band_end = bin + s.cpl_band_sizes[band];
            for (1..@as(usize, s.fbw_channels) + 1) |ch| {
                if (!s.channel_in_cpl[ch]) continue;
                // The int coordinate, exactly a float (few significant bits).
                const cpl_coord = @as(f32, @floatFromInt(s.cpl_coords[ch][band])) * (1.0 / @as(f32, 1 << 23));
                bin = band_start;
                while (bin < band_end) : (bin += 1) s.coeffs[ch][bin] = s.coeffs[cpl_ch][bin] * cpl_coord;
                if (ch == 2 and s.phase_flags[band]) {
                    bin = band_start;
                    while (bin < band_end) : (bin += 1) s.coeffs[2][bin] = -s.coeffs[2][bin];
                }
            }
            bin = band_end;
        }
    }

    const MantGroups = struct {
        b1_mant: [2]i32 = .{ 0, 0 },
        b2_mant: [2]i32 = .{ 0, 0 },
        b4_mant: i32 = 0,
        b1: u8 = 0,
        b2: u8 = 0,
        b4: u8 = 0,
    };

    /// ac3_decode_transform_coeffs_ch.
    fn ac3TransformCoeffsCh(d: *Decoder, r: *bits.BitReader, ch_index: usize, m: *MantGroups) void {
        const s = d.s;
        const dither = ch_index == cpl_ch or s.dither_flag[ch_index];
        for (s.start_freq[ch_index]..s.end_freq[ch_index]) |freq| {
            // "bap %d is invalid in plain AC-3": clamped to 15.
            const bap = @min(s.bap[ch_index][freq], 15);
            var mantissa: i32 = undefined;
            switch (bap) {
                0 => {
                    // Random noise of about -0.707 to 0.707.
                    mantissa = if (dither) @as(i32, @intCast((((d.dith_state.get() >> 8) * 181) >> 8))) - 5931008 else 0;
                },
                1 => if (m.b1 != 0) {
                    m.b1 -= 1;
                    mantissa = m.b1_mant[m.b1];
                } else {
                    const code = r.bits(5);
                    mantissa = bap1_mantissas[code][0];
                    m.b1_mant[1] = bap1_mantissas[code][1];
                    m.b1_mant[0] = bap1_mantissas[code][2];
                    m.b1 = 2;
                },
                2 => if (m.b2 != 0) {
                    m.b2 -= 1;
                    mantissa = m.b2_mant[m.b2];
                } else {
                    const code = r.bits(7);
                    mantissa = bap2_mantissas[code][0];
                    m.b2_mant[1] = bap2_mantissas[code][1];
                    m.b2_mant[0] = bap2_mantissas[code][2];
                    m.b2 = 2;
                },
                3 => mantissa = bap3_mantissas[r.bits(3)],
                4 => if (m.b4 != 0) {
                    m.b4 = 0;
                    mantissa = m.b4_mant;
                } else {
                    const code = r.bits(7);
                    mantissa = bap4_mantissas[code][0];
                    m.b4_mant = bap4_mantissas[code][1];
                    m.b4 = 1;
                },
                5 => mantissa = bap5_mantissas[r.bits(4)],
                else => {
                    // 6 to 15: the mantissa shifted up and sign-extended,
                    // `(unsigned)` so that the shift cannot overflow.
                    const q: u5 = @intCast(quantization_tab[bap]);
                    const v: u32 = @bitCast(r.signed(q));
                    mantissa = @bitCast(v << @intCast(24 - @as(u6, q)));
                },
            }
            // An int of at most 2^24 in magnitude: exactly a float.
            s.coeffs[ch_index][freq] = @as(f32, @floatFromInt(mantissa)) * scale_factors[@intCast(s.dexps[ch_index][freq])];
        }
    }

    /// ff_eac3_decode_transform_coeffs_aht_ch: the six blocks' mantissas
    /// of a channel, read in block 0, then idct6.
    fn ahtTransformCoeffsCh(d: *Decoder, r: *bits.BitReader, ch: usize) void {
        const s = d.s;
        var gaq_gain: [max_coefs]i32 = undefined;
        const gaq_mode = r.bits(2);
        const end_bap: u8 = if (gaq_mode < 2) 12 else 17;
        var gs: usize = 0;
        if (gaq_mode == 1 or gaq_mode == 2) {
            // 1-bit gain codes.
            for (s.start_freq[ch]..s.end_freq[ch]) |bin| {
                if (s.bap[ch][bin] > 7 and s.bap[ch][bin] < end_bap) {
                    gaq_gain[gs] = @as(i32, r.bit()) << @intCast(gaq_mode - 1);
                    gs += 1;
                }
            }
        } else if (gaq_mode == 3) {
            // 1.67-bit gain codes: three in five bits.
            var gc: u8 = 2;
            for (s.start_freq[ch]..s.end_freq[ch]) |bin| {
                if (s.bap[ch][bin] > 7 and s.bap[ch][bin] < 17) {
                    if (gc == 2) {
                        gc = 0;
                        // "GAQ gain group code out-of-range": 26.
                        const group_code = @min(r.bits(5), 26);
                        for (ungroup_3_in_5[group_code]) |g| {
                            gaq_gain[gs] = g;
                            gs += 1;
                        }
                    } else gc += 1;
                }
            }
        }
        gs = 0;
        for (s.start_freq[ch]..s.end_freq[ch]) |bin| {
            const hebap = s.bap[ch][bin];
            const nbits: u32 = eac3_data.bits_vs_hebap[hebap];
            const pre = &s.pre_mantissa[ch][bin];
            if (hebap == 0) {
                // Zero-mantissa dithering.
                for (pre) |*p| p.* = @as(i32, @intCast(d.dith_state.get() & 0x7FFFFF)) - 0x400000;
            } else if (hebap < 8) {
                // Vector quantization.
                const v = r.bits(@intCast(nbits));
                for (pre, eac3_data.mantissa_vq[hebap][v]) |*p, q| p.* = @as(i32, q) * (1 << 8);
            } else {
                // Gain adaptive quantization.
                var log_gain: i32 = 0;
                if (gaq_mode != 0 and hebap < end_bap) {
                    log_gain = gaq_gain[gs];
                    gs += 1;
                }
                const gbits: u32 = nbits - @as(u32, @intCast(log_gain));
                for (pre) |*p| {
                    var mant: i32 = r.signed(@intCast(gbits));
                    if (log_gain != 0 and mant == -(@as(i32, 1) << @intCast(gbits - 1))) {
                        // A large mantissa.
                        const mbits: u32 = nbits - (2 - @as(u32, @intCast(log_gain)));
                        mant = r.signed(@intCast(mbits));
                        mant = @bitCast(@as(u32, @bitCast(mant)) << @intCast(23 - (mbits - 1)));
                        // Asymmetric quantization remapped.
                        const lg: usize = @intCast(log_gain - 1);
                        const b: i32 = if (mant >= 0) @as(i32, 1) << @intCast(23 - log_gain) else eac3_data.gaq_remap_2_4_b[hebap - 8][lg] * (1 << 8);
                        // The int64 sum stored back in the int, truncated
                        // as the reference build's store truncates it
                        // (notes.md "E-AC-3", "AHT's integer arithmetic").
                        mant = @truncate(@as(i64, mant) + ((@as(i64, eac3_data.gaq_remap_2_4_a[hebap - 8][lg]) * mant) >> 15) + b);
                    } else {
                        // A small mantissa, no GAQ, or Gk = 1; the shift
                        // and the store wrap and truncate as the reference
                        // build's (notes.md "AHT's integer arithmetic").
                        mant *%= @as(i32, 1) << @intCast(24 - nbits);
                        if (log_gain == 0) mant = @truncate(@as(i64, mant) + ((@as(i64, eac3_data.gaq_remap_1[hebap - 8]) * mant) >> 15));
                    }
                    p.* = mant;
                }
            }
            idct6(pre);
        }
    }

    fn decodeTransformCoeffsCh(d: *Decoder, r: *bits.BitReader, blk: usize, ch: usize, m: *MantGroups) void {
        const s = d.s;
        if (!s.channel_uses_aht[ch]) return d.ac3TransformCoeffsCh(r, ch, m);
        // AHT: every block's mantissas come in the first block.
        if (blk == 0) d.ahtTransformCoeffsCh(r, ch);
        for (s.start_freq[ch]..s.end_freq[ch]) |bin| {
            s.coeffs[ch][bin] = @as(f32, @floatFromInt(s.pre_mantissa[ch][bin][blk])) * scale_factors[@intCast(s.dexps[ch][bin])];
        }
    }

    fn removeDithering(s: *State) void {
        for (1..@as(usize, s.fbw_channels) + 1) |ch| {
            if (!s.dither_flag[ch] and s.channel_in_cpl[ch]) {
                for (s.start_freq[cpl_ch]..s.end_freq[cpl_ch]) |i| {
                    if (s.bap[cpl_ch][i] == 0) s.coeffs[ch][i] = 0;
                }
            }
        }
    }

    fn decodeTransformCoeffs(d: *Decoder, r: *bits.BitReader, blk: usize) void {
        const s = d.s;
        var got_cplchan = false;
        var m: MantGroups = .{};
        for (1..@as(usize, s.channels) + 1) |ch| {
            d.decodeTransformCoeffsCh(r, blk, ch, &m);
            var end: usize = undefined;
            if (s.channel_in_cpl[ch]) {
                if (!got_cplchan) {
                    d.decodeTransformCoeffsCh(r, blk, cpl_ch, &m);
                    d.calcTransformCoeffsCpl();
                    got_cplchan = true;
                }
                end = s.end_freq[cpl_ch];
            } else end = s.end_freq[ch];
            // `do ... while (++end < 256)`: at least one.
            while (true) {
                s.coeffs[ch][end] = 0;
                end += 1;
                if (end >= 256) break;
            }
        }
        removeDithering(s);
    }

    fn doRematrixing(s: *State) void {
        const end = @min(s.end_freq[1], s.end_freq[2]);
        for (0..s.num_rematrixing_bands) |bnd| {
            if (!s.rematrixing_flags[bnd]) continue;
            const bndend = @min(end, rematrix_band_tab[bnd + 1]);
            var i: usize = rematrix_band_tab[bnd];
            while (i < bndend) : (i += 1) {
                const tmp0 = s.coeffs[1][i];
                s.coeffs[1][i] += s.coeffs[2][i];
                s.coeffs[2][i] = tmp0 - s.coeffs[2][i];
            }
        }
    }

    fn doImdct(d: *Decoder, channels: usize, offset: usize) void {
        const s = d.s;
        for (1..channels + 1) |ch| {
            const out = d.slice(s.outptr[ch - 1]);
            const delay = &s.delay[ch - 1 + offset];
            if (s.block_switch[ch]) {
                var x: [128]f32 = undefined;
                for (&x, 0..) |*v, i| v.* = s.transform_coeffs[ch][2 * i];
                // FFmpeg's x is tmp_output + 128, which the first transform
                // leaves alone.
                @memcpy(s.tmp_output[128..], &x);
                d.mdct128.run(s.tmp_output[0..128], s.tmp_output[128..256]);
                float_dsp.fmulWindow(out, delay, &s.tmp_output, &window, 128);
                for (&x, 0..) |*v, i| v.* = s.transform_coeffs[ch][2 * i + 1];
                @memcpy(s.tmp_output[128..], &x);
                d.mdct128.run(delay[0..128], s.tmp_output[128..256]);
            } else {
                d.mdct256.run(&s.tmp_output, &s.transform_coeffs[ch]);
                float_dsp.fmulWindow(out, delay, &s.tmp_output, &window, 128);
                @memcpy(delay[0..128], s.tmp_output[128..256]);
            }
        }
    }

    /// ac3_upmix_delay, which FFmpeg runs on the first block whose channels
    /// differ in block switching, its delay never having been downmixed
    /// (the independent frame's delay slots, whatever the frame).
    fn upmixDelay(s: *State) void {
        switch (s.channel_mode) {
            ac3.ChannelMode.dual_mono, ac3.ChannelMode.stereo => s.delay[1] = s.delay[0],
            ac3.ChannelMode.f2r2, ac3.ChannelMode.f2r1 => {
                if (s.channel_mode == ac3.ChannelMode.f2r2) s.delay[3] = @splat(0);
                s.delay[2] = @splat(0);
            },
            ac3.ChannelMode.f3r2, ac3.ChannelMode.f3r1, ac3.ChannelMode.f3 => {
                if (s.channel_mode == ac3.ChannelMode.f3r2) s.delay[4] = @splat(0);
                if (s.channel_mode != ac3.ChannelMode.f3) s.delay[3] = @splat(0);
                s.delay[2] = s.delay[1];
                s.delay[1] = @splat(0);
            },
            else => {},
        }
    }

    /// decode_band_structure (no enhanced coupling): `band_struct` is
    /// reset to `default` in block 0, read for the subbands (E-AC-3 only
    /// when a bit asks), and gives the bands' sizes.
    fn decodeBandStructure(r: *bits.BitReader, blk: usize, eac3: bool, start_subband: usize, end_subband: usize, default: []const u8, band_struct: []u8, num_bands: *usize, band_sizes: []u8) void {
        const n_subbands = end_subband - start_subband;
        if (blk == 0) @memcpy(band_struct, default);
        const bs = band_struct[start_subband + 1 ..];
        if (!eac3 or r.bit() != 0) {
            for (0..n_subbands - 1) |subbnd| bs[subbnd] = r.bit();
        }
        var bnd_sz: [22]u8 = undefined;
        var n_bands = n_subbands;
        bnd_sz[0] = 12;
        var bnd: usize = 0;
        for (1..n_subbands) |subbnd| {
            if (bs[subbnd - 1] != 0) {
                n_bands -= 1;
                bnd_sz[bnd] += 12;
            } else {
                bnd += 1;
                bnd_sz[bnd] = 12;
            }
        }
        num_bands.* = n_bands;
        @memcpy(band_sizes[0..n_bands], bnd_sz[0..n_bands]);
    }

    fn spxStrategy(s: *State, r: *bits.BitReader, blk: usize) bool {
        if (s.channel_mode == ac3.ChannelMode.mono) {
            s.channel_uses_spx[1] = true;
        } else {
            var uses = r.bits(@intCast(s.fbw_channels));
            var ch: usize = s.fbw_channels;
            while (ch >= 1) : (ch -= 1) {
                s.channel_uses_spx[ch] = uses & 1 != 0;
                uses >>= 1;
            }
        }
        var dst_start_freq: usize = r.bits(2);
        var start_subband: usize = r.bits(3) + 2;
        if (start_subband > 7) start_subband += start_subband - 7;
        var end_subband: usize = r.bits(3) + 5;
        if (end_subband > 7) end_subband += end_subband - 7;
        dst_start_freq = dst_start_freq * 12 + 25;
        const src_start_freq = start_subband * 12 + 25;
        const dst_end_freq = end_subband * 12 + 25;
        if (start_subband >= end_subband) return false; // "invalid spectral extension range"
        if (dst_start_freq >= src_start_freq) return false; // "invalid spectral extension copy start bin"
        s.spx_dst_start_freq = dst_start_freq;
        s.spx_src_start_freq = src_start_freq;
        s.spx_dst_end_freq = dst_end_freq;
        decodeBandStructure(r, blk, s.eac3, start_subband, end_subband, &default_spx_band_struct, &s.spx_band_struct, &s.num_spx_bands, &s.spx_band_sizes);
        return true;
    }

    fn spxCoordinates(s: *State, r: *bits.BitReader) void {
        for (1..@as(usize, s.fbw_channels) + 1) |ch| {
            if (!s.channel_uses_spx[ch]) {
                s.first_spx_coords[ch] = true;
                continue;
            }
            if (!(s.first_spx_coords[ch] or r.bit() != 0)) continue;
            s.first_spx_coords[ch] = false;
            const spx_blend = @as(f32, @floatFromInt(r.bits(5))) * (1.0 / 32.0);
            const master: u32 = r.bits(2) * 3;
            var bin = s.spx_src_start_freq;
            for (0..s.num_spx_bands) |bnd| {
                const bandsize: usize = s.spx_band_sizes[bnd];
                // The blending factors; noise scaled by sqrt(3) for unity
                // variance.
                var nratio = (@as(f32, @floatFromInt(bin + (bandsize >> 1))) / @as(f32, @floatFromInt(s.spx_dst_end_freq))) - spx_blend;
                nratio = std.math.clamp(nratio, 0.0, 1.0);
                const nblend = @sqrt(3.0 * nratio);
                const sblend = @sqrt(1.0 - nratio);
                bin += bandsize;
                const cexp = r.bits(4);
                var cmant: i32 = @intCast(r.bits(2));
                if (cexp == 15) cmant <<= 1 else cmant += 4;
                cmant <<= @intCast(25 - cexp - master);
                const coord = @as(f32, @floatFromInt(cmant)) * (1.0 / @as(f32, 1 << 23));
                s.spx_noise_blend[ch][bnd] = nblend * coord;
                s.spx_signal_blend[ch][bnd] = sblend * coord;
            }
        }
    }

    /// ff_eac3_apply_spectral_extension.
    fn applySpectralExtension(d: *Decoder) void {
        const s = d.s;
        var wrapflag: [spx_max_bands]bool = @splat(false);
        wrapflag[0] = true;
        var copy_sizes: [spx_max_bands + 1]usize = undefined;
        var num_copy_sections: usize = 0;
        var bin = s.spx_dst_start_freq;
        for (0..s.num_spx_bands) |bnd| {
            const bandsize: usize = s.spx_band_sizes[bnd];
            if (bin + bandsize > s.spx_src_start_freq) {
                copy_sizes[num_copy_sections] = bin - s.spx_dst_start_freq;
                num_copy_sections += 1;
                bin = s.spx_dst_start_freq;
                wrapflag[bnd] = true;
            }
            var i: usize = 0;
            while (i < bandsize) {
                if (bin == s.spx_src_start_freq) {
                    copy_sizes[num_copy_sections] = bin - s.spx_dst_start_freq;
                    num_copy_sections += 1;
                    bin = s.spx_dst_start_freq;
                }
                const copysize = @min(bandsize - i, s.spx_src_start_freq - bin);
                bin += copysize;
                i += copysize;
            }
        }
        copy_sizes[num_copy_sections] = bin - s.spx_dst_start_freq;
        num_copy_sections += 1;
        for (1..@as(usize, s.fbw_channels) + 1) |ch| {
            if (!s.channel_uses_spx[ch]) continue;
            const tc = &s.transform_coeffs[ch];
            // Normal bands copied to the extension bands.
            bin = s.spx_src_start_freq;
            for (copy_sizes[0..num_copy_sections]) |size| {
                @memcpy(tc[bin..][0..size], tc[s.spx_dst_start_freq..][0..size]);
                bin += size;
            }
            // Each band's RMS energy.
            var rms_energy: [spx_max_bands]f32 = undefined;
            bin = s.spx_src_start_freq;
            for (0..s.num_spx_bands) |bnd| {
                const bandsize = s.spx_band_sizes[bnd];
                var accum: f32 = 0;
                for (0..bandsize) |_| {
                    const coeff = tc[bin];
                    bin += 1;
                    accum += coeff * coeff;
                }
                rms_energy[bnd] = @sqrt(accum / @as(f32, @floatFromInt(bandsize)));
            }
            // A notch at the transitions and wrap points.
            if (s.spx_atten_code[ch] >= 0) {
                const atten = eac3_data.spx_atten_tab[@intCast(s.spx_atten_code[ch])];
                bin = s.spx_src_start_freq - 2;
                for (0..s.num_spx_bands) |bnd| {
                    if (wrapflag[bnd]) {
                        const c = tc[bin..][0..5];
                        c[0] *= atten[0];
                        c[1] *= atten[1];
                        c[2] *= atten[2];
                        c[3] *= atten[1];
                        c[4] *= atten[0];
                    }
                    bin += s.spx_band_sizes[bnd];
                }
            }
            // Noise-blended scaling.
            bin = s.spx_src_start_freq;
            for (0..s.num_spx_bands) |bnd| {
                const nscale = s.spx_noise_blend[ch][bnd] * rms_energy[bnd] * (1.0 / @as(f32, -2147483648.0));
                const sscale = s.spx_signal_blend[ch][bnd];
                for (0..s.spx_band_sizes[bnd]) |_| {
                    const noise = nscale * @as(f32, @floatFromInt(@as(i32, @bitCast(d.dith_state.get()))));
                    tc[bin] *= sscale;
                    tc[bin] += noise;
                    bin += 1;
                }
            }
        }
    }

    fn couplingStrategy(s: *State, r: *bits.BitReader, blk: usize, stages: *[max_channels]u8) Error!void {
        @memset(stages, 3);
        if (!s.eac3) s.cpl_in_use[blk] = r.bit() != 0;
        if (s.cpl_in_use[blk]) {
            if (s.channel_mode < ac3.ChannelMode.stereo) return error.InvalidData; // "coupling not allowed in mono or dual-mono"
            // Enhanced coupling: avpriv_request_sample, PATCHWELCOME.
            if (s.eac3 and r.bit() != 0) return error.PatchWelcome;
            if (s.eac3 and s.channel_mode == ac3.ChannelMode.stereo) {
                s.channel_in_cpl[1] = true;
                s.channel_in_cpl[2] = true;
            } else {
                for (1..@as(usize, s.fbw_channels) + 1) |ch| s.channel_in_cpl[ch] = r.bit() != 0;
            }
            if (s.channel_mode == ac3.ChannelMode.stereo) s.phase_flags_in_use = r.bit() != 0;
            const cpl_start_subband: usize = r.bits(4);
            const cpl_end_subband: usize = if (s.spx_in_use) (s.spx_src_start_freq -% 37) / 12 else r.bits(4) + 3;
            if (cpl_start_subband >= cpl_end_subband) return error.InvalidData; // "invalid coupling range"
            s.start_freq[cpl_ch] = cpl_start_subband * 12 + 37;
            s.end_freq[cpl_ch] = cpl_end_subband * 12 + 37;
            decodeBandStructure(r, blk, s.eac3, cpl_start_subband, cpl_end_subband, &default_cpl_band_struct, &s.cpl_band_struct, &s.num_cpl_bands, &s.cpl_band_sizes);
        } else {
            for (1..@as(usize, s.fbw_channels) + 1) |ch| {
                s.channel_in_cpl[ch] = false;
                s.first_cpl_coords[ch] = true;
            }
            s.first_cpl_leak = s.eac3;
            s.phase_flags_in_use = false;
        }
    }

    fn couplingCoordinates(s: *State, r: *bits.BitReader, blk: usize) Error!void {
        var cpl_coords_exist = false;
        for (1..@as(usize, s.fbw_channels) + 1) |ch| {
            if (s.channel_in_cpl[ch]) {
                if ((s.eac3 and s.first_cpl_coords[ch]) or r.bit() != 0) {
                    s.first_cpl_coords[ch] = false;
                    cpl_coords_exist = true;
                    const master: u32 = 3 * r.bits(2);
                    for (0..s.num_cpl_bands) |bnd| {
                        const cexp = r.bits(4);
                        const cmant: i32 = @intCast(r.bits(4));
                        var c: i32 = if (cexp == 15) cmant << 22 else (cmant + 16) << 21;
                        c >>= @intCast(cexp + master);
                        s.cpl_coords[ch][bnd] = c;
                    }
                } else if (blk == 0) return error.InvalidData; // "new coupling coordinates must be present in block 0"
            } else s.first_cpl_coords[ch] = true;
        }
        if (s.channel_mode == ac3.ChannelMode.stereo and cpl_coords_exist) {
            for (0..s.num_cpl_bands) |bnd| s.phase_flags[bnd] = if (s.phase_flags_in_use) r.bit() != 0 else false;
        }
    }

    /// decode_audio_block; an error where FFmpeg returns one.
    fn decodeAudioBlock(d: *Decoder, r: *bits.BitReader, blk: usize, offset: usize) Error!void {
        const s = d.s;
        const fbw: usize = s.fbw_channels;
        const nch: usize = s.channels;
        var stages: [max_channels]u8 = @splat(0);
        // Block switch and dither flags.
        var different_transforms = false;
        if (s.block_switch_syntax) {
            for (1..fbw + 1) |ch| {
                s.block_switch[ch] = r.bit() != 0;
                if (ch > 1 and s.block_switch[ch] != s.block_switch[1]) different_transforms = true;
            }
        }
        if (s.dither_flag_syntax) {
            for (1..fbw + 1) |ch| s.dither_flag[ch] = r.bit() != 0;
        }
        // Dynamic range: `powf(range, drc_scale)` with the scale 1 is the
        // range itself.
        var i: usize = @intFromBool(s.channel_mode == 0);
        while (true) {
            if (r.bit() != 0) {
                s.dynamic_range[i] = dynamic_range_tab[r.bits(8)];
            } else if (blk == 0) s.dynamic_range[i] = 1.0;
            if (i == 0) break;
            i -= 1;
        }
        // Spectral extension strategy.
        if (s.eac3 and (blk == 0 or r.bit() != 0)) {
            s.spx_in_use = r.bit() != 0;
            if (s.spx_in_use and !spxStrategy(s, r, blk)) return error.InvalidData;
        }
        if (!s.eac3 or !s.spx_in_use) {
            s.spx_in_use = false;
            for (1..fbw + 1) |ch| {
                s.channel_uses_spx[ch] = false;
                s.first_spx_coords[ch] = true;
            }
        }
        if (s.spx_in_use) spxCoordinates(s, r);
        // Coupling strategy.
        if (if (s.eac3) s.cpl_strategy_exists[blk] else r.bit() != 0) {
            try couplingStrategy(s, r, blk, &stages);
        } else if (!s.eac3) {
            if (blk == 0) return error.InvalidData; // "new coupling strategy must be present in block 0"
            s.cpl_in_use[blk] = s.cpl_in_use[blk - 1];
        }
        const cpl_in_use = s.cpl_in_use[blk];
        if (cpl_in_use) try couplingCoordinates(s, r, blk);
        // Stereo rematrixing.
        if (s.channel_mode == ac3.ChannelMode.stereo) {
            if ((s.eac3 and blk == 0) or r.bit() != 0) {
                s.num_rematrixing_bands = 4;
                if (cpl_in_use and s.start_freq[cpl_ch] <= 61) {
                    s.num_rematrixing_bands -= 1 + @as(usize, @intFromBool(s.start_freq[cpl_ch] == 37));
                } else if (s.spx_in_use and s.spx_src_start_freq <= 61) {
                    s.num_rematrixing_bands -= 1;
                }
                for (0..s.num_rematrixing_bands) |bnd| s.rematrixing_flags[bnd] = r.bit() != 0;
            } else if (blk == 0) {
                // "new rematrixing strategy not present in block 0".
                s.num_rematrixing_bands = 0;
            }
        }
        const first_ch: usize = @intFromBool(!cpl_in_use);
        // Exponent strategies (E-AC-3's came with the frame).
        for (first_ch..nch + 1) |ch| {
            if (!s.eac3) s.exp_strategy[blk][ch] = @intCast(r.bits(if (ch == s.lfe_ch) 1 else 2));
            if (s.exp_strategy[blk][ch] != exp_reuse) stages[ch] = 3;
        }
        // Channel bandwidth.
        for (1..fbw + 1) |ch| {
            s.start_freq[ch] = 0;
            if (s.exp_strategy[blk][ch] != exp_reuse) {
                const prev = s.end_freq[ch];
                if (s.channel_in_cpl[ch]) {
                    s.end_freq[ch] = s.start_freq[cpl_ch];
                } else if (s.channel_uses_spx[ch]) {
                    s.end_freq[ch] = s.spx_src_start_freq;
                } else {
                    const bandwidth_code = r.bits(6);
                    if (bandwidth_code > 60) return error.InvalidData; // "bandwidth code > 60"
                    s.end_freq[ch] = bandwidth_code * 3 + 73;
                }
                const group_size = @as(usize, 3) << @intCast(s.exp_strategy[blk][ch] - 1);
                s.num_exp_groups[ch] = (s.end_freq[ch] + group_size - 4) / group_size;
                if (blk > 0 and s.end_freq[ch] != prev) @memset(&stages, 3);
            }
        }
        if (cpl_in_use and s.exp_strategy[blk][cpl_ch] != exp_reuse) {
            s.num_exp_groups[cpl_ch] = (s.end_freq[cpl_ch] - s.start_freq[cpl_ch]) / (@as(usize, 3) << @intCast(s.exp_strategy[blk][cpl_ch] - 1));
        }
        // Exponents.
        for (first_ch..nch + 1) |ch| {
            if (s.exp_strategy[blk][ch] == exp_reuse) continue;
            const absexp: u8 = @intCast(r.bits(4) << @intFromBool(ch == 0));
            s.dexps[ch][0] = @intCast(absexp);
            const at = s.start_freq[ch] + @intFromBool(ch != 0);
            if (!decodeExponents(r, s.exp_strategy[blk][ch], s.num_exp_groups[ch], absexp, s.dexps[ch][at..])) return error.InvalidData;
            if (ch != cpl_ch and ch != s.lfe_ch) r.skip(2); // gainrng
        }
        // Bit allocation information.
        if (s.bit_allocation_syntax) {
            if (r.bit() != 0) {
                const ba = &s.bit_alloc_params;
                ba.slow_decay = slow_decay_tab[r.bits(2)] >> @intCast(ba.sr_shift);
                ba.fast_decay = fast_decay_tab[r.bits(2)] >> @intCast(ba.sr_shift);
                ba.slow_gain = slow_gain_tab[r.bits(2)];
                ba.db_per_bit = db_per_bit_tab[r.bits(2)];
                ba.floor = floor_tab[r.bits(3)];
                for (first_ch..nch + 1) |ch| stages[ch] = @max(stages[ch], 2);
            } else if (blk == 0) return error.InvalidData; // "new bit allocation info must be present in block 0"
        }
        // SNR offsets and fast gains.
        if (!s.eac3 or blk == 0) {
            if (s.snr_offset_strategy != 0 and r.bit() != 0) {
                var snr: i32 = 0;
                const csnr: i32 = (@as(i32, @intCast(r.bits(6))) - 15) << 4;
                for (first_ch..nch + 1) |ch| {
                    if (ch == first_ch or s.snr_offset_strategy == 2) snr = (csnr + @as(i32, @intCast(r.bits(4)))) << 2;
                    if (blk != 0 and s.snr_offset[ch] != snr) stages[ch] = @max(stages[ch], 1);
                    s.snr_offset[ch] = snr;
                    if (!s.eac3) {
                        const prev = s.fast_gain[ch];
                        s.fast_gain[ch] = fast_gain_tab[r.bits(3)];
                        if (blk != 0 and prev != s.fast_gain[ch]) stages[ch] = @max(stages[ch], 2);
                    }
                }
            } else if (!s.eac3 and blk == 0) return error.InvalidData; // "new snr offsets must be present in block 0"
        }
        // E-AC-3's fast gains.
        if (s.fast_gain_syntax and r.bit() != 0) {
            for (first_ch..nch + 1) |ch| {
                const prev = s.fast_gain[ch];
                s.fast_gain[ch] = fast_gain_tab[r.bits(3)];
                if (blk != 0 and prev != s.fast_gain[ch]) stages[ch] = @max(stages[ch], 2);
            }
        } else if (s.eac3 and blk == 0) {
            for (first_ch..nch + 1) |ch| s.fast_gain[ch] = fast_gain_tab[4];
        }
        // An E-AC-3 to AC-3 converter's SNR offset.
        if (s.frame_type == ac3.FrameType.independent and r.bit() != 0) r.skip(10);
        // Coupling leak.
        if (cpl_in_use) {
            if (s.first_cpl_leak or r.bit() != 0) {
                const fl: i32 = @intCast(r.bits(3));
                const sl: i32 = @intCast(r.bits(3));
                if (blk != 0 and (fl != s.bit_alloc_params.cpl_fast_leak or sl != s.bit_alloc_params.cpl_slow_leak)) stages[cpl_ch] = @max(stages[cpl_ch], 2);
                s.bit_alloc_params.cpl_fast_leak = fl;
                s.bit_alloc_params.cpl_slow_leak = sl;
            } else if (!s.eac3 and blk == 0) return error.InvalidData; // "new coupling leak info must be present in block 0"
            s.first_cpl_leak = false;
        }
        // Delta bit allocation.
        if (s.dba_syntax and r.bit() != 0) {
            for (first_ch..fbw + 1) |ch| {
                s.dba_mode[ch] = @intCast(r.bits(2));
                if (s.dba_mode[ch] == dba_reserved) return error.InvalidData; // "delta bit allocation strategy reserved"
                stages[ch] = @max(stages[ch], 2);
            }
            for (first_ch..fbw + 1) |ch| {
                if (s.dba_mode[ch] != dba_new) continue;
                s.dba_nsegs[ch] = @intCast(r.bits(3) + 1);
                for (0..@intCast(s.dba_nsegs[ch])) |seg| {
                    s.dba_offsets[ch][seg] = @intCast(r.bits(5));
                    s.dba_lengths[ch][seg] = @intCast(r.bits(4));
                    s.dba_values[ch][seg] = @intCast(r.bits(3));
                }
                stages[ch] = @max(stages[ch], 2);
            }
        } else if (blk == 0) {
            for (0..nch + 1) |ch| s.dba_mode[ch] = dba_none;
        }
        // Bit allocation.
        for (first_ch..nch + 1) |ch| {
            if (stages[ch] > 2) calcPsd(&s.dexps[ch], s.start_freq[ch], s.end_freq[ch], &s.psd[ch], &s.band_psd[ch]);
            if (stages[ch] > 1) {
                const dba: Dba = .{ .mode = s.dba_mode[ch], .nsegs = s.dba_nsegs[ch], .offsets = &s.dba_offsets[ch], .lengths = &s.dba_lengths[ch], .values = &s.dba_values[ch] };
                if (!calcMask(&s.bit_alloc_params, &s.band_psd[ch], s.start_freq[ch], s.end_freq[ch], s.fast_gain[ch], ch == s.lfe_ch, dba, &s.mask[ch])) return error.InvalidData; // "error in bit allocation"
            }
            if (stages[ch] > 0) {
                const tab: *const [64]u8 = if (s.channel_uses_aht[ch]) &hebap_tab else &bap_tab;
                calcBap(&s.mask[ch], &s.psd[ch], s.start_freq[ch], s.end_freq[ch], s.snr_offset[ch], s.bit_alloc_params.floor, tab, &s.bap[ch]);
            }
        }
        // Unused dummy data.
        if (s.skip_syntax and r.bit() != 0) {
            const skipl: i64 = r.bits(9);
            r.skipLong(8 * skipl);
        }
        d.decodeTransformCoeffs(r, blk);
        if (s.channel_mode == ac3.ChannelMode.stereo) doRematrixing(s);
        // Headroom and dynamic range.
        for (1..nch + 1) |ch| {
            var audio_channel: usize = 0;
            if (s.channel_mode == ac3.ChannelMode.dual_mono and ch <= 2) audio_channel = 2 - ch;
            var gain = s.dynamic_range[audio_channel];
            gain *= 1.0 / 4194304.0;
            float_dsp.fmulScalar(&s.transform_coeffs[ch], &s.coeffs[ch], gain);
        }
        if (s.spx_in_use) d.applySpectralExtension();
        // No downmix (the decoder's default): every channel through the
        // IMDCT, the delay upmixed once where block switching differs.
        if (different_transforms and s.downmixed) {
            s.downmixed = false;
            upmixDelay(s);
        }
        d.doImdct(nch, offset);
    }

    /// ac3_decode_frame: one call on `packet` (what remains of it), as
    /// decode.c calls the decoder until the packet is consumed.
    pub fn decode(d: *Decoder, packet: []const u8) Error!Decoded {
        const s = d.s;
        s.superframe_size = 0;
        const full_buf_size = packet.len;
        const sync_at = ac3.findSyncword(packet) orelse return error.InvalidData;
        // A sync word past the first 11 bytes: those bytes consumed, no
        // frame.
        if (sync_at > 10) return .{ .consumed = sync_at, .frame = null };
        const in = packet[sync_at..];
        const copy = @min(in.len, frame_buffer_size);
        if (in.len >= 2 and in[0] == 0x77 and in[1] == 0x0B) {
            // Byte-swapped AC-3: whole 16-bit words swapped in.
            var k: usize = 0;
            while (k + 1 < copy) : (k += 2) {
                d.input[k] = in[k + 1];
                d.input[k + 1] = in[k];
            }
        } else @memcpy(d.input[0..copy], in[0..copy]);
        // `buf` and `buf_size`: the current frame's start in the input
        // buffer, and the bytes from there.
        var base: usize = 0;
        var buf_size: usize = in.len;
        var skip: usize = 0;
        var got_independent_frame = false;
        var err = false;
        while (true) {
            // init_get_bits8 over buf_size bytes; past them the reader sees
            // what the buffer holds.
            const memory = d.input[base..];
            var r = bits.BitReader.initIn(memory, @min(buf_size, memory.len)) catch return error.InvalidData;
            err = false;
            if (d.parseFrameHeader(&r)) |e| switch (e) {
                error.Sync => return error.InvalidData, // "frame sync error"
                error.Bsid, error.SampleRate, error.FrameSize, error.Crc => err = true,
                error.FrameType => {
                    // A substream: skipped when the last id read was one.
                    if (s.substreamid != 0) return .{ .consumed = buf_size, .frame = null };
                    err = true; // "invalid frame type"
                },
                error.ChannelMap => return error.InvalidData,
                error.PatchWelcome => return error.PatchWelcome,
                else => return error.InvalidData,
            } else if (s.frame_size > buf_size) err = true; // "incomplete frame"
            if (s.frame_type == ac3.FrameType.dependent and !got_independent_frame) {
                // "Ignoring dependent frame without independent frame."
                return .{ .consumed = @min(full_buf_size, s.frame_size), .frame = null };
            }
            // Channel configuration.
            if (!err or (s.channels != 0 and s.out_channels != s.channels)) {
                s.out_channels = s.channels;
                s.output_mode = s.channel_mode;
                if (s.lfe_on != 0) s.output_mode |= output_lfeon;
            } else if (s.channels == 0) return error.InvalidData; // "unable to determine channel mode"
            d.ch_layout = ac3.channel_layout_tab[s.output_mode & ~@as(u8, output_lfeon)];
            if (s.output_mode & output_lfeon != 0) d.ch_layout |= ac3.ch.low_frequency;
            const channel_map = dec_channel_map[s.output_mode & ~@as(u8, output_lfeon)][s.lfe_on];
            const offset: usize = if (s.frame_type == ac3.FrameType.dependent) max_channels else 0;
            var output: [max_channels]Ptr = undefined;
            for (0..max_channels) |ch| {
                output[ch] = .{ .frame = false, .ch = @intCast(ch + offset), .off = 0 };
                s.outptr[ch] = output[ch];
            }
            for (0..s.channels) |ch| {
                if (ch < s.out_channels) s.outptr[channel_map[ch]] = .{ .frame = true, .ch = @intCast(ch + offset), .off = 0 };
            }
            const out_channels: usize = s.out_channels;
            for (0..s.num_blocks) |blk| {
                if (!err) d.decodeAudioBlock(&r, blk, offset) catch {
                    err = true; // "error decoding the audio block"
                };
                if (err) {
                    for (0..out_channels) |ch| {
                        var tmp: [block_size]f32 = undefined;
                        @memcpy(&tmp, d.slice(output[ch])[0..block_size]);
                        @memcpy(s.output_buffer[ch + offset][block_size * blk ..][0..block_size], &tmp);
                    }
                }
                for (0..out_channels) |ch| output[ch] = s.outptr[channel_map[ch]];
                for (0..out_channels) |ch| {
                    if (ch == 0 or channel_map[ch] != 0) s.outptr[channel_map[ch]].off += block_size;
                }
            }
            // The last block, kept for concealment in the next frame.
            for (0..out_channels) |ch| {
                var tmp: [block_size]f32 = undefined;
                @memcpy(&tmp, d.slice(output[ch])[0..block_size]);
                s.output[ch + offset] = tmp;
            }
            // A dependent frame after this one.
            if (buf_size > s.frame_size) {
                if (buf_size - s.frame_size <= 16) {
                    skip = buf_size - s.frame_size;
                    break;
                }
                const next_at = base + s.frame_size;
                var next = bits.BitReader.initIn(d.input[next_at..], @min(buf_size - s.frame_size, d.input.len - next_at)) catch return error.InvalidData;
                const hdr = ac3.parseHeader(&next) catch |e| return switch (e) {
                    error.Sync => error.NextSync,
                    error.Bsid => error.NextBsid,
                    error.SampleRate => error.NextSampleRate,
                    error.FrameSize => error.NextFrameSize,
                    error.FrameType => error.NextFrameType,
                    error.ChannelMap => error.NextChannelMap,
                    error.Crc => unreachable, // the header parser never names it
                };
                if (hdr.frame_type == ac3.FrameType.dependent) {
                    if (hdr.num_blocks != s.num_blocks or s.sample_rate != hdr.sample_rate) {
                        // "Ignoring non-compatible dependent frame."
                    } else {
                        base += s.frame_size;
                        buf_size -= s.frame_size;
                        s.prev_output_mode = s.output_mode;
                        s.prev_bit_rate = s.bit_rate;
                        got_independent_frame = true;
                        continue;
                    }
                }
            }
            break;
        }
        if (!err) {
            d.sample_rate = s.sample_rate;
            d.bit_rate = s.bit_rate + s.prev_bit_rate;
        }
        if (d.sample_rate == 0) return error.InvalidData; // "Could not determine the sample rate"
        var mask = ac3.channel_layout_tab[s.output_mode & ~@as(u8, output_lfeon)];
        if (s.output_mode & output_lfeon != 0) mask |= ac3.ch.low_frequency;
        var extended_channel_map: [max_out_channels]usize = undefined;
        for (&extended_channel_map, 0..) |*m, ch| m.* = ch;
        if (s.frame_type == ac3.FrameType.dependent) {
            // The independent frame's layout with the dependent frame's
            // custom channels, each mapped to its decoded channel.
            var ich_layout = ac3.channel_layout_tab[s.prev_output_mode & ~@as(u8, output_lfeon)];
            const channel_map_size: usize = @as(usize, ac3.channels_tab[s.output_mode & ~@as(u8, output_lfeon)]) + s.lfe_on;
            if (s.prev_output_mode & output_lfeon != 0) ich_layout |= ac3.ch.low_frequency;
            var layout = ich_layout;
            for (0..16) |ch| {
                if (s.channel_map & (@as(u32, 1) << @intCast(15 - ch)) != 0) layout |= ac3.custom_channel_map_locations[ch][1];
            }
            if (@popCount(layout) > 16) return error.InvalidData; // "Too many channels coded"
            mask = layout;
            d.ch_layout = layout;
            const channel_map = dec_channel_map[s.output_mode & ~@as(u8, output_lfeon)][s.lfe_on];
            var extend: usize = 0;
            outer: for (0..16) |ch| {
                if (s.channel_map & (@as(u32, 1) << @intCast(15 - ch)) == 0) continue;
                const loc = ac3.custom_channel_map_locations[ch];
                if (loc[0] != 0) {
                    const index = indexOfChannel(layout, @intCast(@ctz(loc[1]))) orelse return error.InvalidData;
                    if (extend >= channel_map_size) break :outer;
                    extended_channel_map[index] = max_channels + channel_map[extend];
                    extend += 1;
                } else {
                    for (0..64) |bit| {
                        if (loc[1] & (@as(u64, 1) << @intCast(bit)) == 0) continue;
                        const index = indexOfChannel(layout, @intCast(bit)) orelse return error.InvalidData;
                        if (extend >= channel_map_size) break;
                        extended_channel_map[index] = max_channels + channel_map[extend];
                        extend += 1;
                    }
                }
            }
        }
        const samples: u32 = s.num_blocks * block_size;
        const channels: u8 = @popCount(mask);
        var frame: Frame = .{
            .planes = undefined,
            .channels = channels,
            .channel_layout = mask,
            .samples = samples,
            .sample_rate = d.sample_rate,
            .concealed = err,
            .downmix = if (s.channel_mode > ac3.ChannelMode.stereo and (s.output_mode & ~@as(u8, output_lfeon)) > ac3.ChannelMode.stereo) .{
                .preferred = s.preferred_downmix,
                .center_mix_level = gain_levels[@intCast(s.center_mix_level)],
                .center_mix_level_ltrt = gain_levels[@intCast(s.center_mix_level_ltrt)],
                .surround_mix_level = gain_levels[@intCast(s.surround_mix_level)],
                .surround_mix_level_ltrt = gain_levels[@intCast(s.surround_mix_level_ltrt)],
                .lfe_mix_level = if (s.lfe_mix_level_exists) gain_levels_lfe[s.lfe_mix_level] else 0.0,
            } else null,
        };
        for (0..channels) |ch| frame.planes[ch] = s.output_buffer[extended_channel_map[ch]][0..samples];
        const total = (if (s.superframe_size == 0) s.frame_size else s.superframe_size) + skip;
        return .{ .consumed = @min(full_buf_size, total), .frame = frame };
    }
};

/// av_channel_layout_index_from_channel for a native layout: the
/// channel's place among the mask's, null when it is not there.
fn indexOfChannel(mask: u64, channel: u6) ?usize {
    const bit = @as(u64, 1) << channel;
    if (mask & bit == 0) return null;
    return @popCount(mask & (bit - 1));
}

const testing = std.testing;

test "the mantissa and band tables match FFmpeg's generated values" {
    try testing.expectEqual(-5592405, bap1_mantissas[0][0]);
    try testing.expectEqual(0, bap1_mantissas[13][1]);
    try testing.expectEqual(49, bin_to_band_tab[252]);
    try testing.expectEqual(28, bin_to_band_tab[30]);
    try testing.expectEqual(1.0, dynamic_range_tab[0]);
    try testing.expectEqual(15.75, dynamic_range_tab[127]);
    try testing.expectEqual(0.0625, dynamic_range_tab[128]);
}

const hostile = @import("../testing/hostile.zig");

/// The fuzz entry's input: a packet, then the stream's rate code (0 to 3,
/// 3 for none), as a value. Every decode call ends in a frame, a frame-less
/// skip or an error, and consumes what FFmpeg's would.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [4096 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const rate_code = smith.valueRangeAtMost(u8, 0, 3);
    var d = try Decoder.init(testing.allocator, ac3.sample_rate_tab[rate_code]);
    defer d.deinit();
    // The packet twice, so that the second decode has state to conceal.
    for (0..2) |_| {
        var rest: []const u8 = input[0..len];
        while (rest.len > 0) {
            const got = d.decode(rest) catch break;
            try testing.expect(got.consumed > 0 and got.consumed <= rest.len);
            if (got.frame) |f| {
                try testing.expectEqual(@popCount(f.channel_layout), f.channels);
                try testing.expectEqual(d.s.num_blocks * block_size, f.samples);
            }
            rest = rest[got.consumed..];
        }
    }
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed(@embedFile("../testing/fixtures/ac3/ac3_ffmpeg_coupling.ac3")[0..512], &.{1}),
    hostile.fuzzSeed(@embedFile("../testing/fixtures/ac3/ac3_ffmpeg_51_48k.ac3")[0..1536], &.{0}),
    hostile.fuzzSeed(@embedFile("../testing/fixtures/ac3/ac3_ffmpeg_mono_32k.ac3")[0..256], &.{2}),
    hostile.fuzzSeed(@embedFile("../testing/fixtures/ac3/ac3_byteswapped.ac3")[0..768], &.{3}),
    hostile.fuzzSeed(@embedFile("../testing/fixtures/eac3/eac3_ffmpeg_51_coupling.eac3")[0..1024], &.{0}),
    hostile.fuzzSeed(@embedFile("../testing/fixtures/eac3/eac3_ffmpeg_lowrate.eac3")[0..512], &.{1}),
};

test "fuzz: the AC-3 decoder on arbitrary packets" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "mutation smoke: the AC-3 decoder on mutated packets" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 64, 0x61633364);
}

fn decodeUnderFailures(gpa: std.mem.Allocator, packet: []const u8) !void {
    var d = try Decoder.init(gpa, 48000);
    defer d.deinit();
    _ = d.decode(packet) catch return error.TestUnexpectedResult;
}

test "malformed E-AC-3 frames: FFmpeg's refusals" {
    const stream = @embedFile("../testing/fixtures/eac3/eac3_ffmpeg_stereo_48k.eac3");
    const size = 768;
    // A frame with its CRC rewritten after the header bytes are changed.
    const Craft = struct {
        fn frame(src: []const u8, byte: usize, mask: u8, value: u8) [size]u8 {
            var f: [size]u8 = src[0..size].*;
            f[byte] = (f[byte] & ~mask) | value;
            std.mem.writeInt(u16, f[size - 2 ..][0..2], bits.Crc16.hash(f[2 .. size - 2]), .big);
            return f;
        }
    };
    // A reduced sample rate (fscod 3): AVERROR_PATCHWELCOME.
    {
        var d = try Decoder.init(testing.allocator, 48000);
        defer d.deinit();
        _ = try d.decode(stream[0..size]);
        const reduced = Craft.frame(stream[size..], 4, 0xF0, 0xC0);
        try testing.expectError(error.PatchWelcome, d.decode(&reduced));
    }
    // A substream 1 frame after an independent frame in one packet: the
    // look for a dependent frame fails the packet with the parse error.
    {
        var d = try Decoder.init(testing.allocator, 48000);
        defer d.deinit();
        var packet: [2 * size]u8 = undefined;
        @memcpy(packet[0..size], stream[0..size]);
        packet[size..].* = Craft.frame(stream[size..], 2, 0x38, 1 << 3);
        try testing.expectError(error.NextFrameType, d.decode(&packet));
    }
    // A dependent frame first: ignored, its size consumed, no frame.
    {
        var d = try Decoder.init(testing.allocator, 48000);
        defer d.deinit();
        const dependent = Craft.frame(stream, 2, 0xC0, 0x40);
        const got = try d.decode(&dependent);
        try testing.expectEqual(size, got.consumed);
        try testing.expectEqual(null, got.frame);
    }
}

test "the AC-3 decoder frees everything under every allocation and remap failure" {
    try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.both, @as([]const u8, @embedFile("../testing/fixtures/ac3/ac3_ffmpeg_stereo_48k.ac3")[0..768]), decodeUnderFailures);
}

test "malformed AC-3 packets: FFmpeg's errors and concealment" {
    var d = try Decoder.init(testing.allocator, 0);
    defer d.deinit();
    // No sync word.
    try testing.expectError(error.InvalidData, d.decode(&.{ 1, 2, 3, 4, 5, 6 }));
    // A sync word past the first 11 bytes: those bytes consumed, no frame.
    var late: [20]u8 = @splat(0);
    late[12] = 0x0B;
    late[13] = 0x77;
    const got = try d.decode(&late);
    try testing.expectEqual(12, got.consumed);
    try testing.expectEqual(null, got.frame);
    // A header with sample rate code 3, before any good frame: no channel
    // mode, INVALIDDATA.
    try testing.expectError(error.InvalidData, d.decode(&.{ 0x0B, 0x77, 0, 0, 0xC0, 0x40, 0x43, 0 }));
    // A cut first frame: concealed, silence, the frame's sizes.
    const frame = @embedFile("../testing/fixtures/ac3/ac3_ffmpeg_stereo_48k.ac3")[0..768];
    var e = try Decoder.init(testing.allocator, 48000);
    defer e.deinit();
    const cut = try e.decode(frame[0..300]);
    try testing.expect(cut.frame.?.concealed);
    try testing.expectEqual(300, cut.consumed);
    for (cut.frame.?.planes[0..2]) |p| for (p) |v| try testing.expectEqual(0, v);
}
