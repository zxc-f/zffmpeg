// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/aac/aacdec.c (count_channels,
// che_configure, frame_configure_elements, assign_pair,
// count_paired_channels, assign_channels, sniff_channel_order,
// push_output_configuration, pop_output_configuration,
// ff_aac_output_configure, ff_aac_set_default_channel_config,
// ff_aac_get_che, decode_channel_map, decode_pce, ff_aac_decode_init,
// skip_data_stream_element, decode_ics_info, decode_band_types,
// decode_scalefactors, decode_pulses, ff_aac_decode_tns,
// decode_mid_side_stereo, ff_aac_decode_ics, decode_cpe,
// decode_drc_channel_exclusions, decode_dynamic_range, decode_fill,
// decode_extension_payload, spectral_to_sample, parse_adts_frame_header,
// decode_frame_ga, aac_decode_frame_int, aac_decode_frame),
// aacdec_proc_template.c (lcg_random, decode_spectrum_and_dequant),
// aacdec_dsp_template.c (dequant_scalefactors, apply_mid_side_stereo,
// apply_intensity_stereo, apply_tns, imdct_and_windowing), aacdec_float.c
// (VMUL2, VMUL4, VMUL2S, VMUL4S, init_dsp's scales),
// aacdec_float_coupling.h (apply_dependent_coupling,
// apply_independent_coupling), aacdec_tab.c
// (ff_tags_per_config, ff_aac_channel_layout_map, ff_aac_channel_map) and
// lpc_functions.h (compute_lpc_coefs) at the pinned reference revision.
// Copyright (c) 2005-2006 Oded Shimon ( ods15 ods15 dyndns org )
// Copyright (c) 2006-2007 Maxim Gavrilov ( maxim.gavrilov gmail com )
// Copyright (c) 2008-2013 Alex Converse <alex.converse@gmail.com>
// Copyright (c) 2010 Rodger Combs <rodger.combs@gmail.com>
// Copyright (c) 2024 Lynne <dev@lynne.ee>
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's float AAC decoder (`aac`, TODO.md T30b), for AAC-LC in ADTS:
//! the frame header, FFmpeg's output configurations and channel mapping,
//! the channel elements (SCE, CPE, LFE, CCE; DSE skipped; PCE; FIL with
//! fill, DRC and a faac marker), ICS info, sections, scale factors, pulses,
//! TNS, the spectral codebooks and dequantization, M/S and intensity
//! stereo, PNS with FFmpeg's random generator, channel coupling, then the
//! IMDCT and window overlap, frame for frame as the pinned decoder computes
//! them (vectors/aac_decode.txt). SSR streams decode with the general
//! syntax, their gain control parsed and ignored, as FFmpeg decodes them.
//! SBR (HE-AAC, T30c) runs through `codec/aacsbr.zig`, and parametric
//! stereo (HE-AACv2, T30d) through `codec/aacps.zig`, each element's state
//! allocated on first use. Main prediction and LTP and the ER and
//! low-delay object types are refused with `UnsupportedFeature` (notes.md
//! "AAC decoder scope").

const std = @import("std");
const bits = @import("bits.zig");
const vlc = @import("vlc.zig");
const tab = @import("aac_tab.zig");
const adts = @import("adts.zig");
const mpeg4audio = @import("mpeg4audio.zig");
const tx = @import("tx.zig");
const float_dsp = @import("float_dsp.zig");
const aacsbr = @import("aacsbr.zig");

pub const Error = error{
    /// FFmpeg's AVERROR_INVALIDDATA.
    InvalidData,
    /// FFmpeg's bare -1: a PCE that runs past the frame.
    Failed,
    /// `ff_adts_header_parse`'s AAC_PARSE_ERROR_SYNC, _SAMPLE_RATE and
    /// _FRAME_SIZE, which the decoder returns as they are.
    AdtsSync,
    AdtsSampleRate,
    AdtsFrameSize,
    /// FFmpeg's AVERROR_PATCHWELCOME: an element id remapped past 15.
    PatchWelcome,
    /// A tool or object type the port does not decode (AVERROR_PATCHWELCOME
    /// in FFmpeg for some; others it decodes: notes.md "AAC decoder scope").
    UnsupportedFeature,
    OutOfMemory,
};

/// `MAX_ELEM_ID`: element ids are 4 bits, remapped ones up to 63.
const max_elem_id = 64;
const max_channels = 64;
/// `MAX_LTP_LONG_SFB`'s companion: 8 windows of 16 bands, or one of 51.
const max_sfb_total = 128;

pub const ElemType = enum(u3) { sce = 0, cpe = 1, cce = 2, lfe = 3, dse = 4, pce = 5, fil = 6, end = 7 };

/// `enum ChannelPosition`.
const Position = struct {
    const off = 0;
    const front = 1;
    const side = 2;
    const back = 3;
    const lfe = 4;
    const cc = 5;
};

/// `enum BandType`.
const BandType = struct {
    const zero = 0;
    const first_pair = 5;
    const esc = 11;
    const noise = 13;
    const intensity2 = 14;
    const intensity = 15;
};

/// `enum WindowSequence`.
const Window = struct {
    const only_long = 0;
    const long_start = 1;
    const eight_short = 2;
    const long_stop = 3;
};

/// `enum OCStatus`.
const OcStatus = enum(u3) { none = 0, trial_pce = 1, trial_frame = 2, global_hdr = 3, locked = 4 };

/// `ff_tags_per_config`.
const tags_per_config = [16]u8{ 0, 1, 1, 2, 3, 3, 4, 5, 0, 0, 0, 5, 5, 16, 5, 0 };

const Tag = [3]u8;

fn t(ty: ElemType, id: u8, pos: u8) Tag {
    return .{ @backingInt(ty), id, pos };
}

/// `ff_aac_channel_layout_map`: by channel configuration less 1.
const channel_layout_map = [16][]const Tag{
    &.{t(.sce, 0, Position.front)},
    &.{t(.cpe, 0, Position.front)},
    &.{ t(.sce, 0, Position.front), t(.cpe, 0, Position.front) },
    &.{ t(.sce, 0, Position.front), t(.cpe, 0, Position.front), t(.sce, 1, Position.back) },
    &.{ t(.sce, 0, Position.front), t(.cpe, 0, Position.front), t(.cpe, 1, Position.back) },
    &.{ t(.sce, 0, Position.front), t(.cpe, 0, Position.front), t(.cpe, 1, Position.back), t(.lfe, 0, Position.lfe) },
    &.{ t(.sce, 0, Position.front), t(.cpe, 0, Position.front), t(.cpe, 1, Position.front), t(.cpe, 2, Position.back), t(.lfe, 0, Position.lfe) },
    &.{},
    &.{},
    &.{},
    &.{ t(.sce, 0, Position.front), t(.cpe, 0, Position.front), t(.cpe, 1, Position.back), t(.sce, 1, Position.back), t(.lfe, 0, Position.lfe) },
    &.{ t(.sce, 0, Position.front), t(.cpe, 0, Position.front), t(.cpe, 1, Position.back), t(.cpe, 2, Position.back), t(.lfe, 0, Position.lfe) },
    &.{
        t(.sce, 0, Position.front), t(.cpe, 0, Position.front), t(.cpe, 1, Position.front), t(.cpe, 2, Position.back),
        t(.cpe, 3, Position.back),  t(.sce, 1, Position.back),  t(.lfe, 0, Position.lfe),   t(.lfe, 1, Position.lfe),
        t(.sce, 2, Position.front), t(.cpe, 4, Position.front), t(.cpe, 5, Position.side),  t(.sce, 3, Position.side),
        t(.cpe, 6, Position.back),  t(.sce, 4, Position.back),  t(.sce, 5, Position.front), t(.cpe, 7, Position.front),
    },
    &.{ t(.sce, 0, Position.front), t(.cpe, 0, Position.front), t(.cpe, 1, Position.back), t(.lfe, 0, Position.lfe), t(.cpe, 2, Position.front) },
    &.{},
    &.{},
};

/// `enum AVChannel` values the map uses; `none` and `unused` as FFmpeg's.
const Chan = struct {
    const none: i16 = -1;
    const unused: i16 = 0x200;
    const fl = 0;
    const fr = 1;
    const fc = 2;
    const lfe = 3;
    const bl = 4;
    const br = 5;
    const flc = 6;
    const frc = 7;
    const bc = 8;
    const sl = 9;
    const sr = 10;
    const tc = 11;
    const tfl = 12;
    const tfc = 13;
    const tfr = 14;
    const tbl = 15;
    const tbc = 16;
    const tbr = 17;
    const lfe2 = 35;
    const tsl = 36;
    const tsr = 37;
    const bfc = 38;
    const bfl = 39;
    const bfr = 40;
};

/// `ff_aac_channel_map`: [layer][position - 1][slot].
const channel_map = [3][4][6]i16{
    .{
        .{ Chan.fc, Chan.flc, Chan.frc, Chan.fl, Chan.fr, Chan.none },
        .{ Chan.unused, Chan.sl, Chan.sr, Chan.none, Chan.none, Chan.none },
        .{ Chan.unused, Chan.sl, Chan.sr, Chan.bl, Chan.br, Chan.bc },
        .{ Chan.lfe, Chan.lfe2, Chan.none, Chan.none, Chan.none, Chan.none },
    },
    .{
        .{ Chan.tfc, Chan.none, Chan.none, Chan.tfl, Chan.tfr, Chan.none },
        .{ Chan.unused, Chan.tsl, Chan.tsr, Chan.none, Chan.none, Chan.tc },
        .{ Chan.unused, Chan.none, Chan.none, Chan.tbl, Chan.tbr, Chan.tbc },
        .{ Chan.none, Chan.none, Chan.none, Chan.none, Chan.none, Chan.none },
    },
    .{
        .{ Chan.bfc, Chan.none, Chan.none, Chan.bfl, Chan.bfr, Chan.none },
        .{ Chan.none, Chan.none, Chan.none, Chan.none, Chan.none, Chan.none },
        .{ Chan.none, Chan.none, Chan.none, Chan.none, Chan.none, Chan.none },
        .{ Chan.none, Chan.none, Chan.none, Chan.none, Chan.none, Chan.none },
    },
};

/// `AV_CH_LAYOUT_22POINT2`.
const layout_22point2: u64 = (1 << Chan.fl) | (1 << Chan.fr) | (1 << Chan.fc) | (1 << Chan.lfe) | (1 << Chan.bl) | (1 << Chan.br) |
    (1 << Chan.flc) | (1 << Chan.frc) | (1 << Chan.bc) | (1 << Chan.lfe2) | (1 << Chan.sl) | (1 << Chan.sr) | (1 << Chan.tfl) |
    (1 << Chan.tfr) | (1 << Chan.tfc) | (1 << Chan.tc) | (1 << Chan.tbl) | (1 << Chan.tbr) | (1 << Chan.tsl) | (1 << Chan.tsr) |
    (1 << Chan.tbc) | (1 << Chan.bfc) | (1 << Chan.bfl) | (1 << Chan.bfr);

/// An output configuration (`OutputConfiguration`): the MPEG-4 config, the
/// element layout and the channel layout it gives.
const OutputConfiguration = struct {
    m4ac: mpeg4audio.Config = .{},
    layout_map: [max_elem_id * 4]Tag = @splat(.{ 0, 0, 0 }),
    layout_map_tags: usize = 0,
    /// The channel mask, or 0 for an unspecified order of `channels`.
    mask: u64 = 0,
    channels: u32 = 0,
    status: OcStatus = .none,
};

/// `IndividualChannelStream`.
const Ics = struct {
    max_sfb: u8 = 0,
    window_sequence: [2]u2 = .{ 0, 0 },
    use_kb_window: [2]u1 = .{ 0, 0 },
    num_window_groups: u8 = 0,
    prev_num_window_groups: u8 = 0,
    group_len: [8]u8 = @splat(0),
    swb_offset: []const u16 = &.{},
    num_swb: u8 = 0,
    num_windows: u8 = 0,
    tns_max_bands: u8 = 0,
    predictor_present: bool = false,
};

/// `TemporalNoiseShaping`.
const Tns = struct {
    present: bool = false,
    n_filt: [8]u8 = @splat(0),
    length: [8][4]u8 = @splat(@splat(0)),
    direction: [8][4]u1 = @splat(@splat(0)),
    order: [8][4]u8 = @splat(@splat(0)),
    coef: [8][4][20]f32 = @splat(@splat(@splat(0))),
};

/// `Pulse`.
const Pulse = struct {
    num_pulse: u8 = 0,
    pos: [4]u32 = @splat(0),
    amp: [4]u8 = @splat(0),
};

/// `SingleChannelElement`, float.
const Sce = struct {
    ics: Ics = .{},
    tns: Tns = .{},
    band_type: [max_sfb_total]u8 = @splat(0),
    sfo: [max_sfb_total]i32 = @splat(0),
    sf: [max_sfb_total]f32 = @splat(0),
    coeffs: [1024]f32 = @splat(0),
    saved: [1536]f32 = @splat(0),
    ret_buf: [2048]f32 = @splat(0),
    /// Where the IMDCT writes: `ret_buf`, or a plane of the output frame.
    output: ?*[2048]f32 = null,

    fn out(s: *Sce) *[2048]f32 {
        return s.output orelse &s.ret_buf;
    }
};

/// `enum CouplingPoint`.
const Coupling = struct {
    const before_tns = 0;
    const between_tns_and_imdct = 1;
    const after_imdct = 3;
};

/// `ChannelCoupling`.
const ChannelCoupling = struct {
    coupling_point: u32 = 0,
    num_coupled: u32 = 0,
    type: [8]ElemType = @splat(.sce),
    id_select: [8]u32 = @splat(0),
    ch_select: [8]u32 = @splat(0),
    gain: [16][120]f32 = @splat(@splat(0)),
};

/// `ChannelElement`, with FFmpeg's `ExtChannelElement`'s SBR state.
const ChannelElement = struct {
    /// The type `che_configure` allocated it for, which its SBR state
    /// starts with.
    alloc_type: u3,
    /// `ff_aac_sbr_ctx_alloc_init`'s state, allocated when the element
    /// first needs it (it starts in the same state either way).
    sbr: ?*aacsbr.Sbr = null,
    present: bool = false,
    ch: [2]Sce = .{ .{}, .{} },
    ms_mask: [max_sfb_total]u1 = @splat(0),
    max_sfb_ste: u8 = 0,
    coup: ChannelCoupling = .{},
};

/// `cce_scale`: 2^(1/8), 2^(1/4), sqrt(2) and 2, as floats.
const cce_scale = [4]f32{ 1.09050773266525765921, 1.18920711500272106672, std.math.sqrt2, 2 };

/// A decoded frame: `samples` per channel in each plane, valid until the
/// next call.
pub const Frame = struct {
    samples: u32,
    sample_rate: u32,
    planes: []const []const f32,
    /// The channel mask, 0 for an unspecified order.
    mask: u64,
};

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    oc: [2]OutputConfiguration = .{ .{}, .{} },
    che: [4][max_elem_id]?*ChannelElement = @splat(@splat(null)),
    tag_che_map: [4][max_elem_id]?*ChannelElement = @splat(@splat(null)),
    /// Each output channel's element.
    output_element: [max_channels]?*Sce = @splat(null),
    tags_mapped: u32 = 0,
    random_state: i32 = 0x1f2e3d4c,
    mdct1024: tx.Mdct,
    mdct128: tx.Mdct,
    buf_mdct: [1024]f32 = @splat(0),
    temp: [128]f32 = @splat(0),
    /// `avctx->ch_layout`, `sample_rate`, `frame_size` and `profile`.
    channels: u32 = 0,
    mask: u64 = 0,
    sample_rate: u32 = 0,
    frame_size: u32 = 0,
    profile: ?i32 = null,
    /// The frame's planes (`ff_get_buffer` with 2048 samples).
    planes: std.ArrayList([2048]f32) = .empty,
    plane_slices: [max_channels][]const f32 = undefined,
    /// `avctx->seek_preroll`: the samples to decode after a seek before
    /// the output is reliable.
    seek_preroll: u32 = 0,
    /// A faac fill element asked libavcodec to skip 1024 samples.
    skip_samples: u32 = 0,

    /// ff_aac_decode_init without extradata (ADTS): the container's rate
    /// and channel count, 0 when it gives none.
    pub fn init(gpa: std.mem.Allocator, sample_rate: u32, channels: u32) Error!Decoder {
        if (sample_rate > 96000) return error.InvalidData;
        var mdct1024 = tx.Mdct.init(gpa, 1024, true, @floatCast(1.0 / 1024.0 / 32768.0)) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable, // 1024 is a supported length
        };
        errdefer mdct1024.deinit();
        var mdct128 = tx.Mdct.init(gpa, 128, true, @floatCast(1.0 / 128.0 / 32768.0)) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable, // 128 is a supported length
        };
        errdefer mdct128.deinit();
        // `avctx->sample_rate` starts as the container's.
        var d: Decoder = .{ .gpa = gpa, .mdct1024 = mdct1024, .mdct128 = mdct128, .sample_rate = sample_rate };
        // The transforms have their own cleanup above.
        errdefer d.deinitElements();
        const m4ac = &d.oc[1].m4ac;
        m4ac.sample_rate = @intCast(sample_rate);
        m4ac.sampling_index = sampleRateIdx(sample_rate);
        m4ac.channels = @intCast(channels);
        m4ac.sbr = -1;
        m4ac.ps = -1;
        var i: usize = 0;
        while (i < mpeg4audio.channel_counts.len and mpeg4audio.channel_counts[i] != channels) i += 1;
        if (i == mpeg4audio.channel_counts.len) i = 0;
        m4ac.chan_config = @intCast(i);
        if (m4ac.chan_config != 0) {
            var map: [max_elem_id * 4]Tag = undefined;
            if (defaultChannelConfig(&map, @intCast(m4ac.chan_config))) |tags| {
                _ = try d.outputConfigure(map[0..tags], .global_hdr, false);
            } else |_| {}
        }
        d.seek_preroll = seekPreroll(&d.oc[1].m4ac);
        if (d.channels > max_channels) return error.InvalidData;
        return d;
    }

    pub fn deinit(d: *Decoder) void {
        d.deinitElements();
        d.mdct1024.deinit();
        d.mdct128.deinit();
        d.* = undefined;
    }

    /// Frees the channel elements and the output planes.
    fn deinitElements(d: *Decoder) void {
        for (&d.che) |*row| for (row) |c| if (c) |p| {
            if (p.sbr) |sbr| sbr.destroy(d.gpa);
            d.gpa.destroy(p);
        };
        d.planes.deinit(d.gpa);
    }

    // ---- Output configuration ----

    /// che_configure: the element allocated (or freed) for its position,
    /// and its channels counted into the output.
    fn cheConfigure(d: *Decoder, pos: u8, ty: u3, id: usize, channels: *usize) Error!void {
        if (channels.* >= max_channels) return error.InvalidData;
        if (pos != Position.off) {
            if (d.che[ty][id] == null) {
                const c = try d.gpa.create(ChannelElement);
                c.* = .{ .alloc_type = ty };
                d.che[ty][id] = c;
            }
            const c = d.che[ty][id].?;
            c.ch[0].output = null;
            c.ch[1].output = null;
            if (ty != @backingInt(ElemType.cce)) {
                const two = ty == @backingInt(ElemType.cpe) or (ty == @backingInt(ElemType.sce) and d.oc[1].m4ac.ps == 1);
                const limit: usize = max_channels;
                if (channels.* >= limit - @intFromBool(two)) return error.InvalidData; // "Too many channels"
                d.output_element[channels.*] = &c.ch[0];
                channels.* += 1;
                if (two) {
                    d.output_element[channels.*] = &c.ch[1];
                    channels.* += 1;
                }
            }
        } else {
            if (d.che[ty][id]) |c| {
                for (&d.tag_che_map) |*row| for (row) |*m| if (m.* == c) {
                    m.* = null;
                };
                if (c.sbr) |sbr| sbr.destroy(d.gpa);
                d.gpa.destroy(c);
            }
            d.che[ty][id] = null;
            d.output_element = @splat(null);
        }
    }

    /// frame_configure_elements: each element's output in its own buffer,
    /// then a new frame (2048 samples a plane), each output channel's
    /// element writing into its plane.
    fn frameConfigureElements(d: *Decoder) Error!bool {
        for (&d.che) |*row| for (row) |c| if (c) |p| {
            p.ch[0].output = null;
            p.ch[1].output = null;
        };
        if (d.channels == 0) return false;
        try d.planes.resize(d.gpa, d.channels);
        for (0..d.channels) |ch| {
            if (d.output_element[ch]) |e| e.output = &d.planes.items[ch];
        }
        return true;
    }

    /// push_output_configuration.
    fn pushOutputConfiguration(d: *Decoder) bool {
        var pushed = false;
        if (d.oc[1].status == .locked or d.oc[0].status == .none) {
            d.oc[0] = d.oc[1];
            pushed = true;
        }
        d.oc[1].status = .none;
        return pushed;
    }

    /// pop_output_configuration.
    fn popOutputConfiguration(d: *Decoder) void {
        if (d.oc[1].status != .locked and d.oc[0].status != .none) {
            d.oc[1] = d.oc[0];
            const map = d.oc[1].layout_map;
            _ = d.outputConfigure(map[0..d.oc[1].layout_map_tags], d.oc[1].status, false) catch {};
        }
    }

    /// ff_aac_output_configure.
    fn outputConfigure(d: *Decoder, map_in: []const Tag, oc_type: OcStatus, get_new_frame: bool) Error!void {
        const tags = map_in.len;
        var map: [max_elem_id * 4]Tag = undefined;
        @memcpy(map[0..tags], map_in);
        var id_map: [8][max_elem_id]u8 = @splat(@splat(0));
        var type_counts: [8]u8 = @splat(0);
        for (map[0..tags]) |e| {
            id_map[e[0]][e[1]] = type_counts[e[0]];
            type_counts[e[0]] += 1;
            if (id_map[e[0]][e[1]] >= max_elem_id) {
                return error.PatchWelcome; // "Too large remapped id"
            }
        }
        // Try to sniff a reasonable channel order.
        const layout_in = sniffChannelOrder(map[0..tags]);
        @memcpy(d.oc[1].layout_map[0..tags], map[0..tags]);
        d.oc[1].layout_map_tags = tags;
        var channels: usize = 0;
        for (map[0..tags]) |e| {
            const iid = id_map[e[0]][e[1]];
            try d.cheConfigure(e[2], @intCast(e[0]), iid, &channels);
            d.tag_che_map[e[0]][e[1]] = d.che[e[0]][iid];
        }
        var layout = layout_in;
        if (d.oc[1].m4ac.ps == 1 and channels == 2) {
            layout = if (layout == (1 << Chan.fc)) (1 << Chan.fl) | (1 << Chan.fr) else 0;
        }
        d.oc[1].mask = layout;
        d.oc[1].channels = if (layout != 0) @popCount(layout) else @intCast(channels);
        d.channels = d.oc[1].channels;
        d.mask = layout;
        d.oc[1].status = oc_type;
        if (get_new_frame) _ = try d.frameConfigureElements();
    }

    /// ff_aac_get_che: the element a frame's element maps to, FFmpeg's
    /// repairs of misordered streams included.
    fn getChe(d: *Decoder, ty: ElemType, elem_id: u8) Error!?*ChannelElement {
        const cfg = d.oc[1].m4ac.chan_config;
        if (cfg == 0) return d.tag_che_map[@backingInt(ty)][elem_id];
        // A single CPE signalled as mono.
        if (d.tags_mapped == 0 and ty == .cpe and cfg == 1) {
            _ = d.pushOutputConfiguration();
            var map: [max_elem_id * 4]Tag = undefined;
            const tags = defaultChannelConfig(&map, 2) catch return null;
            d.outputConfigure(map[0..tags], .trial_frame, true) catch return null;
            d.oc[1].m4ac.chan_config = 2;
            d.oc[1].m4ac.ps = 0;
        }
        // And vice versa.
        if (d.tags_mapped == 0 and ty == .sce and d.oc[1].m4ac.chan_config == 2) {
            _ = d.pushOutputConfiguration();
            const map = [_]Tag{ t(.sce, 0, Position.front), t(.sce, 1, Position.front) };
            d.outputConfigure(&map, .trial_frame, true) catch return null;
            if (d.oc[1].m4ac.sbr != 0) d.oc[1].m4ac.ps = -1;
        }
        const ti = @backingInt(ty);
        const chan_config = d.oc[1].m4ac.chan_config;
        var step: i32 = chan_config;
        // The switch's fall-through, case by case.
        while (true) : (step = nextCase(step)) {
            switch (step) {
                14 => if (d.tags_mapped > 2 and ((ty == .cpe and elem_id < 3) or (ty == .lfe and elem_id < 1))) {
                    return d.mapTo(ti, elem_id, d.che[ti][elem_id]);
                },
                13 => if (d.tags_mapped > 3 and ((ty == .cpe and elem_id < 8) or (ty == .sce and elem_id < 6) or (ty == .lfe and elem_id < 2))) {
                    return d.mapTo(ti, elem_id, d.che[ti][elem_id]);
                },
                12, 7 => if (d.tags_mapped == 3 and ty == .cpe) {
                    return d.mapTo(ti, elem_id, d.che[@backingInt(ElemType.cpe)][2]);
                },
                11 => if (d.tags_mapped == 3 and ty == .sce) {
                    return d.mapTo(ti, elem_id, d.che[@backingInt(ElemType.sce)][1]);
                },
                6 => if (d.tags_mapped == tags_per_config[@intCast(chan_config)] -% 1 and (ty == .lfe or ty == .sce)) {
                    return d.mapTo(ti, elem_id, d.che[@backingInt(ElemType.lfe)][0]);
                },
                5 => if (d.tags_mapped == 2 and ty == .cpe) {
                    return d.mapTo(ti, elem_id, d.che[@backingInt(ElemType.cpe)][1]);
                },
                4 => {
                    if (d.tags_mapped == tags_per_config[@intCast(chan_config)] -% 1 and (ty == .lfe or ty == .sce))
                        return d.mapTo(ti, elem_id, d.che[@backingInt(ElemType.sce)][1]);
                    if (d.tags_mapped == 2 and chan_config == 4 and ty == .sce)
                        return d.mapTo(ti, elem_id, d.che[@backingInt(ElemType.sce)][1]);
                },
                3, 2 => {
                    if (d.tags_mapped == @intFromBool(chan_config != 2) and ty == .cpe)
                        return d.mapTo(ti, elem_id, d.che[@backingInt(ElemType.cpe)][0]);
                    if (d.tags_mapped == 1 and chan_config == 2 and ty == .sce)
                        return d.mapTo(ti, elem_id, d.che[@backingInt(ElemType.sce)][1]);
                },
                1 => if (d.tags_mapped == 0 and ty == .sce) {
                    return d.mapTo(ti, elem_id, d.che[@backingInt(ElemType.sce)][0]);
                },
                else => return null,
            }
        }
    }

    fn mapTo(d: *Decoder, ti: u3, elem_id: u8, c: ?*ChannelElement) ?*ChannelElement {
        d.tags_mapped += 1;
        d.tag_che_map[ti][elem_id] = c;
        return c;
    }

    // ---- Frames ----

    /// aac_decode_frame: one packet; the bytes consumed (the whole packet
    /// when only zeros follow the frame) and the frame, if any.
    pub fn decode(d: *Decoder, packet: []const u8) Error!struct { consumed: usize, frame: ?Frame } {
        if (packet.len >= std.math.maxInt(i32) / 8) return error.InvalidData;
        var r = bits.BitReader.init(packet) catch return error.InvalidData;
        switch (d.oc[1].m4ac.object_type) {
            mpeg4audio.aot.er_aac_lc, 19, mpeg4audio.aot.er_aac_ld, mpeg4audio.aot.er_aac_eld => return error.UnsupportedFeature,
            else => {},
        }
        const samples = try d.decodeFrameInt(&r);
        const consumed = (r.count() + 7) >> 3;
        var offset = consumed;
        while (offset < packet.len and packet[offset] == 0) offset += 1;
        const used = if (packet.len > offset) consumed else packet.len;
        if (samples == 0) return .{ .consumed = used, .frame = null };
        for (0..d.channels) |ch| d.plane_slices[ch] = d.planes.items[ch][0..samples];
        return .{ .consumed = used, .frame = .{ .samples = samples, .sample_rate = d.sample_rate, .planes = d.plane_slices[0..d.channels], .mask = d.mask } };
    }

    /// aac_decode_frame_int: the frame's samples, 0 for none.
    fn decodeFrameInt(d: *Decoder, r: *bits.BitReader) Error!u32 {
        return d.decodeFrameIntInner(r) catch |err| {
            d.popOutputConfiguration();
            return err;
        };
    }

    fn decodeFrameIntInner(d: *Decoder, r: *bits.BitReader) Error!u32 {
        if (r.peek(12) == 0xfff and d.oc[1].m4ac.object_type != mpeg4audio.aot.usac) {
            try d.parseAdtsFrameHeader(r);
            if (d.oc[1].m4ac.sampling_index > 12) return error.InvalidData;
        }
        _ = try d.frameConfigureElements();
        d.profile = d.oc[1].m4ac.object_type - 1;
        d.tags_mapped = 0;
        // FFmpeg decodes Main's prediction and LTP, whose state runs from
        // frame to frame; not ported. Any other object type is decoded with
        // the general syntax (SSR's gain control parsed and ignored).
        switch (d.oc[1].m4ac.object_type) {
            mpeg4audio.aot.aac_main, mpeg4audio.aot.aac_ltp => return error.UnsupportedFeature,
            else => {},
        }
        return d.decodeFrameGa(r);
    }

    /// parse_adts_frame_header.
    fn parseAdtsFrameHeader(d: *Decoder, r: *bits.BitReader) Error!void {
        var head: [adts.header_size]u8 = undefined;
        for (&head) |*b| b.* = @intCast(r.bits(8));
        const hdr = adts.parseHeader(&head) catch |err| return switch (err) {
            error.Sync => error.AdtsSync,
            error.SampleRate => error.AdtsSampleRate,
            error.FrameSize => error.AdtsFrameSize,
        };
        _ = d.pushOutputConfiguration();
        if (hdr.chan_config != 0) {
            d.oc[1].m4ac.chan_config = hdr.chan_config;
            var map: [max_elem_id * 4]Tag = undefined;
            const tags = try defaultChannelConfig(&map, hdr.chan_config);
            const status: OcStatus = @fromBackingInt(@intCast(@max(@backingInt(d.oc[1].status), @backingInt(OcStatus.trial_frame))));
            try d.outputConfigure(map[0..tags], status, false);
        } else {
            d.oc[1].m4ac.chan_config = 0;
        }
        d.oc[1].m4ac.sample_rate = @intCast(hdr.sample_rate);
        d.oc[1].m4ac.sampling_index = hdr.sampling_index;
        d.oc[1].m4ac.object_type = hdr.object_type;
        d.oc[1].m4ac.frame_length_short = 0;
        if (d.oc[0].status != .locked or d.oc[0].m4ac.chan_config != hdr.chan_config or d.oc[0].m4ac.sample_rate != hdr.sample_rate) {
            d.oc[1].m4ac.sbr = -1;
            d.oc[1].m4ac.ps = -1;
        }
        if (!hdr.crc_absent) r.skip(16);
    }

    /// decode_frame_ga: the elements to END, then the samples; their
    /// count, 0 for no frame.
    fn decodeFrameGa(d: *Decoder, r: *bits.BitReader) Error!u32 {
        var che_presence: [4][max_elem_id]u8 = @splat(@splat(0));
        var che_prev: ?*ChannelElement = null;
        var elem_type_prev: ElemType = .fil;
        var samples: u32 = 0;
        var audio_found = false;
        var pce_found = false;
        const payload_alignment = r.count();
        while (true) {
            const elem_type: ElemType = @fromBackingInt(@intCast(r.bits(3)));
            if (elem_type == .end) break;
            // An int: a DRC payload may use more bytes than are left, which
            // ends the FIL loop below.
            var elem_id: i64 = r.bits(4);
            if (d.channels == 0 and elem_type != .pce) return error.InvalidData;
            var che: ?*ChannelElement = null;
            if (@backingInt(elem_type) < @backingInt(ElemType.dse)) {
                const presence = &che_presence[@backingInt(elem_type)][@intCast(elem_id)];
                // A first duplicate is only logged.
                if (presence.* > 1) return error.InvalidData;
                presence.* += 1;
                che = try d.getChe(elem_type, @intCast(elem_id)) orelse return error.InvalidData; // "channel element %d.%d is not allocated"
                samples = 1024;
                che.?.present = true;
            }
            switch (elem_type) {
                .sce, .lfe => {
                    try decodeIcsImpl(d, &che.?.ch[0], r, false);
                    audio_found = true;
                },
                .cpe => {
                    try decodeCpeImpl(d, r, che.?);
                    audio_found = true;
                },
                .cce => try decodeCce(d, r, che.?),
                .dse => try skipDataStreamElement(r),
                .pce => {
                    var map: [max_elem_id * 4]Tag = @splat(.{ 0, 0, 0 });
                    const pushed = d.pushOutputConfiguration();
                    if (pce_found and !pushed) return error.InvalidData;
                    const tags = try decodePce(r, &map, payload_alignment);
                    if (pce_found) {
                        d.popOutputConfiguration();
                    } else {
                        try d.outputConfigure(map[0..tags], .trial_pce, true);
                        d.oc[1].m4ac.chan_config = 0;
                        pce_found = true;
                    }
                },
                .fil => {
                    // C's int: a count byte of 0 gives 14.
                    if (elem_id == 15) elem_id += @as(i64, r.bits(8)) - 1;
                    if (r.left() < 8 * elem_id) return error.InvalidData;
                    while (elem_id > 0) {
                        const used = try d.decodeExtensionPayload(r, @intCast(elem_id), che_prev, elem_type_prev);
                        elem_id -= used;
                    }
                },
                .end => unreachable,
            }
            if (@backingInt(elem_type) < @backingInt(ElemType.dse)) {
                che_prev = che;
                elem_type_prev = elem_type;
            }
            if (r.left() < 3) return error.InvalidData;
        }
        if (d.channels == 0) return 0;
        // SBR doubles the samples and the rate, unless it is downsampled.
        const m4ac = &d.oc[1].m4ac;
        const multiplier: u5 = if (m4ac.sbr == 1) @intFromBool(m4ac.ext_sample_rate > m4ac.sample_rate) else 0;
        samples <<= multiplier;
        try d.spectralToSample(samples);
        if (d.oc[1].status != .none and audio_found) {
            d.sample_rate = @as(u32, @intCast(d.oc[1].m4ac.sample_rate)) << multiplier;
            d.frame_size = samples;
            // Implicit SBR is only known once found in a frame.
            d.seek_preroll = @max(d.seek_preroll, seekPreroll(&d.oc[1].m4ac));
            d.oc[1].status = .locked;
        }
        if (samples != 0 and d.sample_rate == 0) return error.InvalidData; // "Cannot output a frame without a valid sample rate"
        return samples;
    }

    /// spectral_to_sample without coupling, LTP or SBR: each present
    /// element's TNS and IMDCT; an absent one's output silenced.
    fn spectralToSample(d: *Decoder, samples: u32) Error!void {
        var ty: usize = 4;
        while (ty > 0) {
            ty -= 1;
            for (0..max_elem_id) |i| {
                const c = d.che[ty][i] orelse continue;
                if (c.present) {
                    const elem: ElemType = @fromBackingInt(@intCast(ty));
                    if (ty <= @backingInt(ElemType.cpe)) d.applyChannelCoupling(c, elem, i, Coupling.before_tns, .dependent);
                    if (c.ch[0].tns.present) applyTns(&c.ch[0].coeffs, &c.ch[0].tns, &c.ch[0].ics);
                    if (c.ch[1].tns.present) applyTns(&c.ch[1].coeffs, &c.ch[1].tns, &c.ch[1].ics);
                    if (ty <= @backingInt(ElemType.cpe)) d.applyChannelCoupling(c, elem, i, Coupling.between_tns_and_imdct, .dependent);
                    if (ty != @backingInt(ElemType.cce) or c.coup.coupling_point == Coupling.after_imdct) {
                        imdctAndWindowing(d, &c.ch[0]);
                        if (ty == @backingInt(ElemType.cpe)) imdctAndWindowing(d, &c.ch[1]);
                        if (d.oc[1].m4ac.sbr > 0) {
                            const sbr = try d.sbrOf(c);
                            sbr.apply(@intCast(ty), &d.oc[1].m4ac, c.ch[0].out(), c.ch[1].out());
                        }
                    }
                    if (ty <= @backingInt(ElemType.cce)) d.applyChannelCoupling(c, elem, i, Coupling.after_imdct, .independent);
                    c.present = false;
                } else {
                    @memset(c.ch[0].out()[0..samples], 0);
                    if (ty == @backingInt(ElemType.cpe)) @memset(c.ch[1].out()[0..samples], 0);
                }
            }
        }
    }

    /// apply_channel_coupling: every CCE coupled at `point` into element
    /// `elem_id` of type `ty`.
    fn applyChannelCoupling(d: *Decoder, cc: *ChannelElement, ty: ElemType, elem_id: usize, point: u32, method: enum { dependent, independent }) void {
        for (0..max_elem_id) |i| {
            const cce = d.che[@backingInt(ElemType.cce)][i] orelse continue;
            if (cce.coup.coupling_point != point) continue;
            const coup = &cce.coup;
            var index: usize = 0;
            for (0..coup.num_coupled + 1) |c| {
                if (coup.type[c] == ty and coup.id_select[c] == elem_id) {
                    if (coup.ch_select[c] != 1) {
                        applyCoupling(&cc.ch[0], cce, index, method == .dependent, d.oc[1].m4ac.sbr == 1);
                        if (coup.ch_select[c] != 0) index += 1;
                    }
                    if (coup.ch_select[c] != 2) {
                        applyCoupling(&cc.ch[1], cce, index, method == .dependent, d.oc[1].m4ac.sbr == 1);
                        index += 1;
                    }
                } else index += 1 + @as(usize, @intFromBool(coup.ch_select[c] == 3));
            }
        }
    }

    /// The element's SBR state, allocated on first use.
    fn sbrOf(d: *Decoder, c: *ChannelElement) Error!*aacsbr.Sbr {
        if (c.sbr) |sbr| return sbr;
        const sbr = try aacsbr.Sbr.create(d.gpa, c.alloc_type);
        c.sbr = sbr;
        return sbr;
    }

    /// decode_extension_payload: the bytes used of `cnt`, after the
    /// element `che` of type `elem_type`.
    fn decodeExtensionPayload(d: *Decoder, r: *bits.BitReader, cnt: u32, che_in: ?*ChannelElement, elem_type: ElemType) Error!u32 {
        const ext_type = r.bits(4);
        switch (ext_type) {
            // EXT_SBR_DATA, EXT_SBR_DATA_CRC.
            0xd, 0xe => {
                const che = che_in orelse return cnt; // "SBR was found before the first channel element"
                const m4ac = &d.oc[1].m4ac;
                if (m4ac.sbr == 0) {
                    // "SBR signaled to be not-present but was found in the
                    // bitstream."
                    r.skipLong(8 * @as(i64, cnt) - 4);
                    return cnt;
                } else if (m4ac.sbr == -1 and d.oc[1].status == .locked) {
                    // "Implicit SBR was found with a first occurrence after
                    // the first frame."
                    r.skipLong(8 * @as(i64, cnt) - 4);
                    return cnt;
                } else if (m4ac.ps == -1 and @backingInt(d.oc[1].status) < @backingInt(OcStatus.locked) and d.channels == 1) {
                    // HE-AAC mono is output as stereo, FFmpeg's implicit
                    // parametric stereo.
                    m4ac.sbr = 1;
                    m4ac.ps = 1;
                    const tags = d.oc[1].layout_map_tags;
                    var map: [max_elem_id * 4]Tag = undefined;
                    @memcpy(map[0..tags], d.oc[1].layout_map[0..tags]);
                    try d.outputConfigure(map[0..tags], d.oc[1].status, true);
                } else {
                    m4ac.sbr = 1;
                }
                const sbr = try d.sbrOf(che);
                _ = try sbr.decodeExtension(r, ext_type == 0xe, cnt, @intCast(@backingInt(elem_type)), &d.oc[1].m4ac);
                return cnt;
            },
            // EXT_DYNAMIC_RANGE.
            0xb => return decodeDynamicRange(r),
            // EXT_FILL.
            0x0 => {
                d.decodeFill(r, 8 * @as(i64, cnt) - 4);
                return cnt;
            },
            else => {
                r.skipLong(8 * @as(i64, cnt) - 4);
                return cnt;
            },
        }
    }

    /// decode_fill: a faac marker asks for 1024 samples skipped.
    fn decodeFill(d: *Decoder, r: *bits.BitReader, len_in: i64) void {
        var len = len_in;
        if (len >= 13 + 7 * 8) {
            _ = r.bits(13);
            len -= 13;
            var buf: [256]u8 = undefined;
            var i: usize = 0;
            while (i + 1 < buf.len and len >= 8) : ({
                i += 1;
                len -= 8;
            }) buf[i] = @intCast(r.bits(8));
            buf[i] = 0;
            if (faacVersion(buf[0..i])) d.skip_samples = 1024;
        }
        r.skipLong(len);
    }
};

/// `sscanf(buf, "libfaac %d.%d", &major, &minor) == 2`.
fn faacVersion(text_in: []const u8) bool {
    const text = text_in[0 .. std.mem.findScalar(u8, text_in, 0) orelse text_in.len];
    if (!std.mem.startsWith(u8, text, "libfaac")) return false;
    var rest = text["libfaac".len..];
    // %d skips white space, then a sign and digits.
    rest = std.mem.trimStart(u8, rest, " \t\n\r\x0b\x0c");
    rest = scanInt(rest) orelse return false;
    if (rest.len == 0 or rest[0] != '.') return false;
    return scanInt(rest[1..]) != null;
}

fn scanInt(text_in: []const u8) ?[]const u8 {
    var text = std.mem.trimStart(u8, text_in, " \t\n\r\x0b\x0c");
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) text = text[1..];
    var n: usize = 0;
    while (n < text.len and std.ascii.isDigit(text[n])) n += 1;
    return if (n == 0) null else text[n..];
}

/// The case after `c` in ff_aac_get_che's fall-through order.
fn nextCase(c: i32) i32 {
    return switch (c) {
        14 => 13,
        13 => 12,
        12, 7 => 11,
        11 => 6,
        6 => 5,
        5 => 4,
        4 => 3,
        3, 2 => 1,
        else => 0,
    };
}

/// seek_preroll: the frame before (and, with SBR, one more), for the
/// object types this decoder takes.
fn seekPreroll(m4ac: *const mpeg4audio.Config) u32 {
    const frame: u32 = if (m4ac.frame_length_short != 0) 960 else 1024;
    const frames: u32 = 1 + @as(u32, @intFromBool(m4ac.sbr == 1));
    const upsampled: u5 = @intFromBool(m4ac.sbr == 1 and m4ac.ext_sample_rate > m4ac.sample_rate);
    return (frame * frames) << upsampled;
}

/// ff_aac_sample_rate_idx.
fn sampleRateIdx(rate: u32) i32 {
    const bounds = [_]u32{ 92017, 75132, 55426, 46009, 37566, 27713, 23004, 18783, 13856, 11502, 9391 };
    for (bounds, 0..) |b, i| if (rate >= b) return @intCast(i);
    return 11;
}

/// ff_aac_set_default_channel_config: the configuration's layout and its
/// tag count; configuration 7 as 7.1, not 7.1(wide), as FFmpeg assumes
/// below `-strict strict`.
fn defaultChannelConfig(map: *[max_elem_id * 4]Tag, config: u32) Error!usize {
    if (config < 1 or (config > 7 and config < 11) or config > 14) return error.InvalidData;
    const tags: usize = tags_per_config[config];
    @memcpy(map[0..tags], channel_layout_map[config - 1][0..tags]);
    if (config == 7) map[2][2] = Position.back;
    return tags;
}

/// `count_paired_channels`.
fn countPairedChannels(map: []const Tag, pos: u8, current: usize) i32 {
    var num: i32 = 0;
    var first_cpe = false;
    var sce_parity = false;
    for (map[current..]) |e| {
        if (e[2] != pos) break;
        if (e[0] == @backingInt(ElemType.cpe)) {
            if (sce_parity) {
                if (pos == Position.front and !first_cpe) sce_parity = false else return -1;
            }
            num += 2;
            first_cpe = true;
        } else {
            num += 1;
            if (pos != Position.lfe) sce_parity = !sce_parity;
        }
    }
    if (sce_parity and pos == Position.front and first_cpe) return -1;
    return num;
}

/// `struct elem_to_channel`.
const ElemToChannel = struct {
    av_position: u64 = 0,
    syn_ele: u8 = 0,
    elem_id: u8 = 0,
    aac_position: u8 = 0,
};

fn assignPair(e2c: []ElemToChannel, map: []const Tag, offset: usize, left: u64, right: u64, pos: u8, layout: *u64) usize {
    if (map[offset][0] == @backingInt(ElemType.cpe)) {
        e2c[offset] = .{ .av_position = left | right, .syn_ele = @backingInt(ElemType.cpe), .elem_id = map[offset][1], .aac_position = pos };
        layout.* |= e2c[offset].av_position;
        return 1;
    }
    e2c[offset] = .{ .av_position = left, .syn_ele = @backingInt(ElemType.sce), .elem_id = map[offset][1], .aac_position = pos };
    e2c[offset + 1] = .{ .av_position = right, .syn_ele = @backingInt(ElemType.sce), .elem_id = map[offset + 1][1], .aac_position = pos };
    layout.* |= left | right;
    return 2;
}

fn bit(c: i16) u64 {
    return @as(u64, 1) << @intCast(c);
}

/// `assign_channels`: false for FFmpeg's -1.
fn assignChannels(e2c: []ElemToChannel, map: []const Tag, layout: *u64, layer: usize, pos: u8, current: *usize) bool {
    var i = current.*;
    var nb = countPairedChannels(map, pos, i);
    if (nb < 0 or nb > 5) return true;
    const row = &channel_map[layer][pos - 1];
    if (pos == Position.lfe) {
        var j: usize = 0;
        while (nb > 0) : (nb -= 1) {
            if (row[j] == Chan.none) return false;
            e2c[i] = .{ .av_position = bit(row[j]), .syn_ele = map[i][0], .elem_id = map[i][1], .aac_position = pos };
            layout.* |= e2c[i].av_position;
            i += 1;
            j += 1;
        }
        current.* = i;
        return true;
    }
    while (nb & 1 != 0) {
        if (row[0] == Chan.none) return false;
        if (row[0] == Chan.unused) break;
        e2c[i] = .{ .av_position = bit(row[0]), .syn_ele = map[i][0], .elem_id = map[i][1], .aac_position = pos };
        layout.* |= e2c[i].av_position;
        i += 1;
        nb -= 1;
    }
    var j: usize = if (pos != Position.side and nb <= 3) 3 else 1;
    while (nb >= 2) {
        if (row[j] == Chan.none or row[j + 1] == Chan.none) return false;
        i += assignPair(e2c, map, i, bit(row[j]), bit(row[j + 1]), pos, layout);
        j += 2;
        nb -= 2;
    }
    while (nb & 1 != 0) {
        if (row[5] == Chan.none) return false;
        e2c[i] = .{ .av_position = bit(row[5]), .syn_ele = map[i][0], .elem_id = map[i][1], .aac_position = pos };
        layout.* |= e2c[i].av_position;
        i += 1;
        nb -= 1;
    }
    if (nb != 0) return false;
    current.* = i;
    return true;
}

/// sniff_channel_order: the layout's mask, `map` reordered to it; 0 when
/// none fits.
fn sniffChannelOrder(map: []Tag) u64 {
    var e2c: [4 * max_elem_id]ElemToChannel = @splat(.{});
    var layout: u64 = 0;
    const tags = map.len;
    if (e2c.len < tags) return 0;
    var i: usize = 0;
    var n: usize = 0;
    while (n < 3 and i < tags) : (n += 1) {
        inline for (.{ Position.front, Position.side, Position.back, Position.lfe }) |pos| {
            if (!assignChannels(&e2c, map, &layout, n, pos, &i)) return 0;
        }
    }
    const total = i;
    if (layout == layout_22point2) {
        std.mem.swap(ElemToChannel, &e2c[2], &e2c[0]);
        std.mem.swap(ElemToChannel, &e2c[2], &e2c[1]);
        std.mem.swap(ElemToChannel, &e2c[6], &e2c[2]);
        std.mem.swap(ElemToChannel, &e2c[4], &e2c[3]);
        std.mem.swap(ElemToChannel, &e2c[6], &e2c[4]);
        std.mem.swap(ElemToChannel, &e2c[7], &e2c[6]);
        std.mem.swap(ElemToChannel, &e2c[9], &e2c[8]);
        std.mem.swap(ElemToChannel, &e2c[11], &e2c[10]);
        std.mem.swap(ElemToChannel, &e2c[12], &e2c[11]);
    } else {
        // A stable bubble sort by position.
        var m = total;
        while (m > 0) {
            var next_m: usize = 0;
            for (1..m) |k| {
                if (e2c[k - 1].av_position > e2c[k].av_position) {
                    std.mem.swap(ElemToChannel, &e2c[k - 1], &e2c[k]);
                    next_m = k;
                }
            }
            m = next_m;
        }
    }
    for (0..total) |k| map[k] = .{ e2c[k].syn_ele, e2c[k].elem_id, e2c[k].aac_position };
    return layout;
}

/// skip_data_stream_element.
fn skipDataStreamElement(r: *bits.BitReader) Error!void {
    const byte_align = r.bit();
    var count: i64 = r.bits(8);
    if (count == 255) count += r.bits(8);
    if (byte_align != 0) r.alignByte();
    if (r.left() < 8 * count) return error.InvalidData;
    r.skipLong(8 * count);
}

/// decode_channel_map.
fn decodeChannelMap(map: []Tag, pos: u8, r: *bits.BitReader, n: u32) void {
    for (map[0..n]) |*e| {
        const syn: u8 = switch (pos) {
            Position.front, Position.back, Position.side => r.bit(),
            Position.cc => blk: {
                r.skip(1);
                break :blk @backingInt(ElemType.cce);
            },
            Position.lfe => @backingInt(ElemType.lfe),
            else => unreachable, // the callers' positions
        };
        e.* = .{ syn, @intCast(r.bits(4)), pos };
    }
}

/// decode_pce: the tags of the layout it declares.
fn decodePce(r: *bits.BitReader, map: *[max_elem_id * 4]Tag, byte_align_ref: usize) Error!usize {
    r.skip(2); // object_type
    _ = r.bits(4); // sampling_index, only compared for a warning
    const num_front = r.bits(4);
    const num_side = r.bits(4);
    const num_back = r.bits(4);
    const num_lfe = r.bits(2);
    const num_assoc_data = r.bits(3);
    const num_cc = r.bits(4);
    if (r.bit() != 0) r.skip(4);
    if (r.bit() != 0) r.skip(4);
    if (r.bit() != 0) r.skip(3);
    if (r.left() < 5 * @as(i64, num_front + num_side + num_back + num_cc) + 4 * @as(i64, num_lfe + num_assoc_data + num_cc)) return error.Failed;
    var tags: usize = 0;
    decodeChannelMap(map[tags..], Position.front, r, num_front);
    tags += num_front;
    decodeChannelMap(map[tags..], Position.side, r, num_side);
    tags += num_side;
    decodeChannelMap(map[tags..], Position.back, r, num_back);
    tags += num_back;
    decodeChannelMap(map[tags..], Position.lfe, r, num_lfe);
    tags += num_lfe;
    r.skipLong(4 * @as(i64, num_assoc_data));
    decodeChannelMap(map[tags..], Position.cc, r, num_cc);
    tags += num_cc;
    // relative_align_get_bits.
    const n: usize = (byte_align_ref -% r.count()) & 7;
    if (n != 0) r.skip(n);
    var comment_len: i64 = @as(i64, r.bits(8)) * 8;
    if (r.left() < comment_len) return error.InvalidData;
    // The height extension.
    const nfsb: i64 = num_front * 2 + num_side * 2 + num_back * 2;
    if (comment_len >= 16 + nfsb and r.peek(8) == 0xac) {
        r.skip(8);
        var height_map: [4][16]u8 = undefined;
        var tag: [6][16]Tag = undefined;
        var invalid = false;
        var ht: usize = 0;
        inline for (.{ Position.front, Position.side, Position.back }, .{ num_front, num_side, num_back }) |pos, count| {
            for (0..count) |i| {
                const height: u8 = @intCast(r.bits(2));
                invalid = invalid or height > 2;
                height_map[pos][i] = height;
                tag[pos][i] = map[ht];
                ht += 1;
            }
        }
        for (0..num_lfe) |i| {
            tag[Position.lfe][i] = map[ht];
            ht += 1;
        }
        for (0..num_cc) |i| {
            tag[Position.cc][i] = map[ht];
            ht += 1;
        }
        if (!invalid) {
            ht = 0;
            for (0..3) |level| {
                inline for (.{ Position.front, Position.side, Position.back }, .{ num_front, num_side, num_back }) |pos, count| {
                    for (0..count) |j| if (height_map[pos][j] == level) {
                        map[ht] = tag[pos][j];
                        ht += 1;
                    };
                }
                if (level == 0) {
                    for (0..num_lfe) |j| {
                        map[ht] = tag[Position.lfe][j];
                        ht += 1;
                    }
                    for (0..num_cc) |j| {
                        map[ht] = tag[Position.cc][j];
                        ht += 1;
                    }
                }
            }
        }
        comment_len -= 8 + nfsb;
    }
    r.skipLong(comment_len);
    return tags;
}

/// decode_dynamic_range: the bytes used (the values are not applied by the
/// float decoder).
fn decodeDynamicRange(r: *bits.BitReader) u32 {
    var n: u32 = 1;
    var num_bands: u32 = 1;
    if (r.bit() != 0) {
        r.skip(8); // pce_instance_tag, tag_reserved_bits
        n += 1;
    }
    if (r.bit() != 0) {
        // decode_drc_channel_exclusions.
        var num_excl: u32 = 0;
        while (true) {
            r.skip(7);
            num_excl += 7;
            if (!(num_excl < max_channels - 7 and r.bit() != 0)) break;
        }
        n += num_excl / 7;
    }
    if (r.bit() != 0) {
        const band_incr = r.bits(4);
        r.skip(4); // interpolation_scheme
        n += 1;
        num_bands += band_incr;
        r.skipLong(8 * @as(i64, num_bands));
        n += num_bands;
    }
    if (r.bit() != 0) {
        r.skip(8); // prog_ref_level, its reserved bit
        n += 1;
    }
    r.skipLong(8 * @as(i64, num_bands));
    n += num_bands;
    return n;
}

// ---- Channel streams ----

/// `lcg_random`.
fn lcgRandom(previous: i32) i32 {
    const u: u32 = @bitCast(previous);
    return @bitCast(u *% 1664525 +% 1013904223);
}

fn decodeIcsInfo(d: *Decoder, ics: *Ics, r: *bits.BitReader) Error!void {
    const m4ac = &d.oc[1].m4ac;
    const sampling_index: usize = @intCast(m4ac.sampling_index);
    // "Reserved bit set" is only logged by default.
    _ = r.bit();
    ics.window_sequence[1] = ics.window_sequence[0];
    ics.window_sequence[0] = @intCast(r.bits(2));
    ics.use_kb_window[1] = ics.use_kb_window[0];
    ics.use_kb_window[0] = r.bit();
    ics.prev_num_window_groups = @max(ics.num_window_groups, 1);
    ics.num_window_groups = 1;
    ics.group_len[0] = 1;
    if (ics.window_sequence[0] == Window.eight_short) {
        ics.max_sfb = @intCast(r.bits(4));
        for (0..7) |_| {
            if (r.bit() != 0) {
                ics.group_len[ics.num_window_groups - 1] += 1;
            } else {
                ics.num_window_groups += 1;
                ics.group_len[ics.num_window_groups - 1] = 1;
            }
        }
        ics.num_windows = 8;
        ics.swb_offset = tab.swb_offset_128[sampling_index];
        ics.num_swb = tab.num_swb_128[sampling_index];
        ics.tns_max_bands = tab.tns_max_bands_128[sampling_index];
        ics.predictor_present = false;
    } else {
        ics.max_sfb = @intCast(r.bits(6));
        ics.num_windows = 1;
        ics.num_swb = tab.num_swb_1024[sampling_index];
        ics.swb_offset = tab.swb_offset_1024[sampling_index];
        ics.tns_max_bands = tab.tns_max_bands_1024[sampling_index];
        ics.predictor_present = r.bit() != 0;
        if (ics.predictor_present) {
            const aot = m4ac.object_type;
            // Main's prediction (refused with the object type).
            if (aot == mpeg4audio.aot.aac_main) return error.UnsupportedFeature;
            if (aot == mpeg4audio.aot.aac_lc or aot == mpeg4audio.aot.er_aac_lc) {
                // "Prediction is not allowed in AAC-LC."
                ics.max_sfb = 0;
                return error.InvalidData;
            }
            // Long-term prediction's data, parsed (applied only for the LTP
            // object type, refused).
            if (r.bit() != 0) skipLtp(r, ics.max_sfb);
        }
    }
    if (ics.max_sfb > ics.num_swb) {
        ics.max_sfb = 0;
        return error.InvalidData;
    }
}

/// decode_ltp, its values unused: the lag, the coefficient, and a flag
/// for each band up to `MAX_LTP_LONG_SFB`.
fn skipLtp(r: *bits.BitReader, max_sfb: u8) void {
    r.skip(11 + 3);
    r.skip(@min(max_sfb, 40));
}

/// decode_gain_control, whose data FFmpeg reads and ignores.
fn decodeGainControl(sce: *const Sce, r: *bits.BitReader) void {
    // wd_num, wd_test, aloc_size by window sequence.
    const gain_mode = [4][3]u8{ .{ 1, 0, 5 }, .{ 2, 1, 2 }, .{ 8, 0, 2 }, .{ 2, 1, 5 } };
    const mode = gain_mode[sce.ics.window_sequence[0]];
    const max_band = r.bits(2);
    for (0..max_band) |_| {
        for (0..mode[0]) |wd| {
            const adjust_num = r.bits(3);
            for (0..adjust_num) |_| r.skip(4 + @as(usize, if (wd == 0 and mode[1] != 0) 4 else mode[2]));
        }
    }
}

fn decodeBandTypes(sce: *Sce, r: *bits.BitReader) Error!void {
    const ics = &sce.ics;
    const nbits: u6 = if (ics.window_sequence[0] == Window.eight_short) 3 else 5;
    const esc = (@as(u32, 1) << @intCast(nbits)) - 1;
    for (0..ics.num_window_groups) |g| {
        var k: usize = 0;
        while (k < ics.max_sfb) {
            // A uint8_t in FFmpeg, compared as it wraps.
            var sect_end: u8 = @intCast(k);
            const sect_band_type: u8 = @intCast(r.bits(4));
            if (sect_band_type == 12) return error.InvalidData; // "invalid band type"
            while (true) {
                const incr = r.bits(nbits);
                sect_end +%= @truncate(incr);
                if (r.left() < 0) return error.InvalidData;
                if (sect_end > ics.max_sfb) return error.InvalidData; // "Number of bands exceeds limit"
                if (incr != esc) break;
            }
            while (k < sect_end) : (k += 1) sce.band_type[g * ics.max_sfb + k] = sect_band_type;
        }
    }
}

const scale_diff_zero = 60;
const noise_pre = 256;
const noise_pre_bits = 9;
const noise_offset = 90;

fn scalefactorCode(r: *bits.BitReader) i32 {
    return vlc.lookup(bits.BitReader, &tab.scalefactor_vlc, r, tab.scalefactor_vlc_bits, 3);
}

fn decodeScalefactors(sce: *Sce, r: *bits.BitReader, global_gain: i32) Error!void {
    const ics = &sce.ics;
    var offset = [3]i32{ global_gain, global_gain - noise_offset, 0 };
    var noise_flag: i32 = 1;
    for (0..ics.num_window_groups) |g| {
        for (0..ics.max_sfb) |sfb| {
            const i = g * ics.max_sfb + sfb;
            switch (sce.band_type[i]) {
                BandType.zero => sce.sfo[i] = 0,
                BandType.intensity, BandType.intensity2 => {
                    offset[2] += scalefactorCode(r) - scale_diff_zero;
                    sce.sfo[i] = std.math.clamp(offset[2], -155, 100) - 100;
                },
                BandType.noise => {
                    if (noise_flag > 0) {
                        offset[1] += @as(i32, @intCast(r.bits(noise_pre_bits))) - noise_pre;
                    } else {
                        offset[1] += scalefactorCode(r) - scale_diff_zero;
                    }
                    noise_flag -= 1;
                    sce.sfo[i] = std.math.clamp(offset[1], -100, 155);
                },
                else => {
                    offset[0] += scalefactorCode(r) - scale_diff_zero;
                    // "Scalefactor out of range": 0 to 255, compared unsigned.
                    if (offset[0] < 0 or offset[0] > 255) return error.InvalidData;
                    sce.sfo[i] = offset[0] - 100;
                },
            }
        }
    }
}

/// dequant_scalefactors (float).
fn dequantScalefactors(sce: *Sce) void {
    const ics = &sce.ics;
    var idx: usize = 0;
    for (0..ics.num_window_groups) |g| {
        for (0..ics.max_sfb) |sfb| {
            const sfo = sce.sfo[idx];
            sce.sf[idx] = switch (sce.band_type[g * ics.max_sfb + sfb]) {
                BandType.zero => 0,
                BandType.intensity, BandType.intensity2 => tab.pow2sf_tab[@intCast(-sfo - 100 + tab.pow2sf_zero)],
                else => -tab.pow2sf_tab[@intCast(sfo + tab.pow2sf_zero)],
            };
            idx += 1;
        }
    }
}

fn decodePulses(pulse: *Pulse, r: *bits.BitReader, swb_offset: []const u16, num_swb: u8) bool {
    pulse.num_pulse = @intCast(r.bits(2) + 1);
    const pulse_swb = r.bits(6);
    if (pulse_swb >= num_swb) return false;
    pulse.pos[0] = swb_offset[pulse_swb] + r.bits(5);
    if (pulse.pos[0] >= swb_offset[num_swb]) return false;
    pulse.amp[0] = @intCast(r.bits(4));
    for (1..pulse.num_pulse) |i| {
        pulse.pos[i] = r.bits(5) + pulse.pos[i - 1];
        if (pulse.pos[i] >= swb_offset[num_swb]) return false;
        pulse.amp[i] = @intCast(r.bits(4));
    }
    return true;
}

/// ff_aac_decode_tns (AAC-LC: orders up to 12, 7 in short windows).
fn decodeTns(tns: *Tns, r: *bits.BitReader, ics: *const Ics) Error!void {
    const is8 = ics.window_sequence[0] == Window.eight_short;
    const k: u6 = @intFromBool(is8);
    const max_order: u32 = if (is8) 7 else 12;
    for (0..ics.num_windows) |w| {
        tns.n_filt[w] = @intCast(r.bits(2 - k));
        if (tns.n_filt[w] == 0) continue;
        const coef_res = r.bit();
        for (0..tns.n_filt[w]) |filt| {
            tns.length[w][filt] = @intCast(r.bits(6 - 2 * k));
            tns.order[w][filt] = @intCast(r.bits(5 - 2 * k));
            if (tns.order[w][filt] > max_order) {
                tns.order[w][filt] = 0;
                return error.InvalidData;
            }
            if (tns.order[w][filt] == 0) continue;
            tns.direction[w][filt] = r.bit();
            const coef_compress = r.bit();
            const coef_len: u6 = @as(u6, coef_res) + 3 - coef_compress;
            const tmp2_idx = 2 * @as(usize, coef_compress) + coef_res;
            for (0..tns.order[w][filt]) |i| tns.coef[w][filt][i] = tab.tns_tmp2_map[tmp2_idx][r.bits(coef_len)];
        }
    }
}

/// ff_aac_decode_ics.
fn decodeIcsInner(d: *Decoder, sce: *Sce, r: *bits.BitReader, common_window: bool) Error!void {
    var pulse: Pulse = .{};
    const global_gain: i32 = @intCast(r.bits(8));
    if (!common_window) try decodeIcsInfo(d, &sce.ics, r);
    try decodeBandTypes(sce, r);
    try decodeScalefactors(sce, r, global_gain);
    dequantScalefactors(sce);
    const pulse_present = r.bit() != 0;
    if (pulse_present) {
        // "Pulse tool not allowed in eight short sequence."
        if (sce.ics.window_sequence[0] == Window.eight_short) return error.InvalidData;
        if (!decodePulses(&pulse, r, sce.ics.swb_offset, sce.ics.num_swb)) return error.InvalidData;
    }
    sce.tns.present = r.bit() != 0;
    if (sce.tns.present) try decodeTns(&sce.tns, r, &sce.ics);
    // Gain control (SSR), parsed and ignored as FFmpeg ignores it.
    if (r.bit() != 0) decodeGainControl(sce, r);
    try decodeSpectrumAndDequantImpl(d, r, if (pulse_present) &pulse else null, sce);
}

fn decodeIcsImpl(d: *Decoder, sce: *Sce, r: *bits.BitReader, common_window: bool) Error!void {
    decodeIcsInner(d, sce, r, common_window) catch |err| {
        sce.sfo = @splat(0);
        sce.tns.present = false;
        return err;
    };
}

fn decodeCpeImpl(d: *Decoder, r: *bits.BitReader, cpe: *ChannelElement) Error!void {
    var ms_present: u32 = 0;
    const common_window = r.bit() != 0;
    if (common_window) {
        try decodeIcsInfo(d, &cpe.ch[0].ics, r);
        const kb = cpe.ch[1].ics.use_kb_window[0];
        cpe.ch[1].ics = cpe.ch[0].ics;
        cpe.ch[1].ics.use_kb_window[1] = kb;
        if (cpe.ch[1].ics.predictor_present and d.oc[1].m4ac.object_type != mpeg4audio.aot.aac_main) {
            if (r.bit() != 0) skipLtp(r, cpe.ch[1].ics.max_sfb);
        }
        ms_present = r.bits(2);
        if (ms_present == 3) return error.InvalidData; // "ms_present = 3 is reserved."
        if (ms_present != 0) {
            // decode_mid_side_stereo.
            const max_idx = @as(usize, cpe.ch[0].ics.num_window_groups) * cpe.ch[0].ics.max_sfb;
            cpe.max_sfb_ste = cpe.ch[0].ics.max_sfb;
            if (ms_present == 1) {
                for (cpe.ms_mask[0..max_idx]) |*m| m.* = r.bit();
            } else {
                @memset(cpe.ms_mask[0..max_idx], 1);
            }
        }
    }
    try decodeIcsImpl(d, &cpe.ch[0], r, common_window);
    try decodeIcsImpl(d, &cpe.ch[1], r, common_window);
    if (common_window and ms_present != 0) applyMidSideStereo(cpe);
    applyIntensityStereo(cpe, ms_present);
}

fn applyMidSideStereo(cpe: *ChannelElement) void {
    const ics = &cpe.ch[0].ics;
    const offsets = ics.swb_offset;
    var base: usize = 0;
    for (0..ics.num_window_groups) |g| {
        for (0..cpe.max_sfb_ste) |sfb| {
            const idx = g * cpe.max_sfb_ste + sfb;
            if (cpe.ms_mask[idx] != 0 and cpe.ch[0].band_type[idx] < BandType.noise and cpe.ch[1].band_type[idx] < BandType.noise) {
                for (0..ics.group_len[g]) |group| {
                    const at = base + group * 128 + offsets[sfb];
                    const len = offsets[sfb + 1] - offsets[sfb];
                    float_dsp.butterflies(cpe.ch[0].coeffs[at..][0..len], cpe.ch[1].coeffs[at..][0..len]);
                }
            }
        }
        base += @as(usize, ics.group_len[g]) * 128;
    }
}

fn applyIntensityStereo(cpe: *ChannelElement, ms_present: u32) void {
    const sce1 = &cpe.ch[1];
    const ics = &sce1.ics;
    const offsets = ics.swb_offset;
    var base: usize = 0;
    for (0..ics.num_window_groups) |g| {
        for (0..ics.max_sfb) |sfb| {
            const idx = g * ics.max_sfb + sfb;
            const bt = sce1.band_type[idx];
            if (bt == BandType.intensity or bt == BandType.intensity2) {
                var c: i32 = -1 + 2 * (@as(i32, bt) - 14);
                if (ms_present != 0) c *= 1 - 2 * @as(i32, cpe.ms_mask[idx]);
                const scale = @as(f32, @floatFromInt(c)) * sce1.sf[idx];
                for (0..ics.group_len[g]) |group| {
                    const at = base + group * 128 + offsets[sfb];
                    const len = offsets[sfb + 1] - offsets[sfb];
                    float_dsp.fmulScalar(cpe.ch[1].coeffs[at..][0..len], cpe.ch[0].coeffs[at..][0..len], scale);
                }
            }
        }
        base += @as(usize, ics.group_len[g]) * 128;
    }
}

/// `avpriv_scalarproduct_float_c`.
fn scalarProduct(v: []const f32) f32 {
    var p: f32 = 0.0;
    for (v) |x| p += x * x;
    return p;
}

/// The float with `bits` toggled in its sign bit (`av_intfloat32`).
fn signed(v: f32, sign_bit: u32) f32 {
    return @bitCast(@as(u32, @bitCast(v)) ^ (sign_bit & 0x8000_0000));
}

fn decodeSpectrumAndDequantImpl(d: *Decoder, r: *bits.BitReader, pulse: ?*const Pulse, sce: *Sce) Error!void {
    const ics = &sce.ics;
    const c: usize = 1024 / @as(usize, ics.num_windows);
    const offsets = ics.swb_offset;
    const coef = &sce.coeffs;
    for (0..ics.num_windows) |g| @memset(coef[g * 128 + offsets[ics.max_sfb] .. g * 128 + c], 0);
    var base: usize = 0;
    var idx: usize = 0;
    for (0..ics.num_window_groups) |g| {
        const g_len = ics.group_len[g];
        for (0..ics.max_sfb) |i| {
            defer idx += 1;
            const cbt_m1: u32 = @as(u32, sce.band_type[idx]) -% 1;
            const off_len: usize = offsets[i + 1] - offsets[i];
            var cfo = base + offsets[i];
            if (cbt_m1 >= BandType.intensity2 - 1) {
                for (0..g_len) |_| {
                    @memset(coef[cfo..][0..off_len], 0);
                    cfo += 128;
                }
            } else if (cbt_m1 == BandType.noise - 1) {
                for (0..g_len) |_| {
                    const band = coef[cfo..][0..off_len];
                    for (band) |*v| {
                        d.random_state = lcgRandom(d.random_state);
                        v.* = @floatFromInt(d.random_state);
                    }
                    const band_energy = scalarProduct(band);
                    const scale = sce.sf[idx] / @sqrt(band_energy);
                    float_dsp.fmulScalar(band, band, scale);
                    cfo += 128;
                }
            } else {
                const vq = tab.codebook_vector_vals[cbt_m1];
                const table = tab.spectral_vlc[cbt_m1];
                const s = sce.sf[idx];
                for (0..g_len) |_| {
                    var cf = cfo;
                    const end = cfo + off_len;
                    switch (cbt_m1 >> 1) {
                        0 => while (cf < end) {
                            const cb: u32 = @bitCast(vlc.lookup(bits.BitReader, table, r, tab.spectral_vlc_bits, 2));
                            // VMUL4.
                            inline for (0..4) |k| coef[cf + k] = vq[(cb >> (2 * k)) & 3] * s;
                            cf += 4;
                        },
                        1 => while (cf < end) {
                            const cb: u32 = @bitCast(vlc.lookup(bits.BitReader, table, r, tab.spectral_vlc_bits, 2));
                            const nnz: u6 = @intCast(cb >> 8 & 15);
                            // GET_CACHE: the next 32 bits, left-aligned.
                            var sign: u32 = if (nnz != 0) r.peek(32) else 0;
                            r.skip(nnz);
                            // VMUL4S.
                            var nz = cb >> 12;
                            const sb: u32 = @bitCast(s);
                            inline for (0..4) |k| {
                                coef[cf + k] = vq[(cb >> (2 * k)) & 3] * @as(f32, @bitCast(sb ^ (sign & 0x8000_0000)));
                                if (k < 3) {
                                    sign <<= @intCast(nz & 1);
                                    nz >>= 1;
                                }
                            }
                            cf += 4;
                        },
                        2 => while (cf < end) {
                            const cb: u32 = @bitCast(vlc.lookup(bits.BitReader, table, r, tab.spectral_vlc_bits, 2));
                            // VMUL2.
                            coef[cf] = vq[cb & 15] * s;
                            coef[cf + 1] = vq[(cb >> 4) & 15] * s;
                            cf += 2;
                        },
                        3, 4 => while (cf < end) {
                            const cb: u32 = @bitCast(vlc.lookup(bits.BitReader, table, r, tab.spectral_vlc_bits, 2));
                            const nnz: u6 = @intCast(cb >> 8 & 15);
                            // SHOW_UBITS(nnz) << (cb_idx >> 12): a 32-bit
                            // shift, its count taken mod 32 as x86's shl.
                            const sign: u32 = if (nnz != 0) r.peek(nnz) << @intCast((cb >> 12) & 31) else 0;
                            r.skip(nnz);
                            // VMUL2S.
                            coef[cf] = vq[cb & 15] * signed(s, (sign >> 1) << 31);
                            coef[cf + 1] = vq[(cb >> 4) & 15] * signed(s, sign << 31);
                            cf += 2;
                        },
                        else => {
                            const icf: []u32 = @ptrCast(coef);
                            while (cf < end) {
                                var cb: u32 = @bitCast(vlc.lookup(bits.BitReader, table, r, tab.spectral_vlc_bits, 2));
                                if (cb == 0) {
                                    icf[cf] = 0;
                                    icf[cf + 1] = 0;
                                    cf += 2;
                                    continue;
                                }
                                const nnz: u6 = @intCast((cb >> 12) & 0xf);
                                const nzt = cb >> 8;
                                var sbits: u32 = if (nnz != 0) r.peek(nnz) << @intCast(32 - @as(u7, nnz)) else 0;
                                r.skip(nnz);
                                for (0..2) |j| {
                                    if (nzt & (@as(u32, 1) << @intCast(j)) != 0) {
                                        // The escape: a unary prefix of at
                                        // most 8 ones, then 4 more bits than
                                        // ones.
                                        const cache = r.peek(32);
                                        const b: u32 = if (~cache == 0) 32 else @clz(~cache);
                                        if (b > 8) return error.InvalidData; // "ESC overflow"
                                        r.skip(b + 1);
                                        const nb: u6 = @intCast(b + 4);
                                        const n = (@as(u32, 1) << @intCast(nb)) + r.bits(nb);
                                        icf[cf] = tab.cbrt_tab[n] | (sbits & 0x8000_0000);
                                        sbits <<= 1;
                                    } else {
                                        const v: u32 = @bitCast(vq[cb & 15]);
                                        icf[cf] = (sbits & 0x8000_0000) | v;
                                        if (v != 0) sbits <<= 1;
                                    }
                                    cf += 1;
                                    cb >>= 4;
                                }
                            }
                            float_dsp.fmulScalar(coef[cfo..][0..off_len], coef[cfo..][0..off_len], s);
                        },
                    }
                    cfo += 128;
                }
            }
        }
        base += @as(usize, g_len) << 7;
    }
    if (pulse) |p| {
        var bi: usize = 0;
        for (0..p.num_pulse) |i| {
            var co = coef[p.pos[i]];
            while (offsets[bi + 1] <= p.pos[i]) bi += 1;
            if (sce.band_type[bi] != BandType.noise and sce.sf[bi] != 0) {
                var ico: f32 = -@as(f32, @floatFromInt(p.amp[i]));
                if (co != 0) {
                    co /= sce.sf[bi];
                    ico = co / @sqrt(@sqrt(@abs(co))) + (if (co > 0) -ico else ico);
                }
                coef[p.pos[i]] = libm.cbrtf(@abs(ico)) * ico * sce.sf[bi];
            }
        }
    }
}

const libm = @import("../core/libm.zig");

/// compute_lpc_coefs without normalization (TNS's reflection
/// coefficients to the all-pole filter), in float.
fn computeLpcCoefs(coefs: []const f32, lpc: []f32) void {
    for (coefs, 0..) |autoc, i| {
        // `LPC_SRA_R(-autoc[i], 5)`, a plain negation in float.
        const r = -autoc;
        lpc[i] = r;
        for (0..(i + 1) >> 1) |j| {
            const f = lpc[j];
            const b = lpc[i - 1 - j];
            lpc[j] = f + r * b;
            lpc[i - 1 - j] = b + r * f;
        }
    }
}

/// apply_tns (decode).
fn applyTns(coef: *[1024]f32, tns: *const Tns, ics: *const Ics) void {
    const mmm: usize = @min(ics.tns_max_bands, ics.max_sfb);
    if (mmm == 0) return;
    for (0..ics.num_windows) |w| {
        var bottom: i32 = ics.num_swb;
        for (0..tns.n_filt[w]) |filt| {
            const top = bottom;
            bottom = @max(0, top - @as(i32, tns.length[w][filt]));
            const order = tns.order[w][filt];
            if (order == 0) continue;
            var lpc: [20]f32 = undefined;
            computeLpcCoefs(tns.coef[w][filt][0..order], &lpc);
            var start: i64 = ics.swb_offset[@min(@as(usize, @intCast(bottom)), mmm)];
            const end: i64 = ics.swb_offset[@min(@as(usize, @intCast(top)), mmm)];
            const size = end - start;
            if (size <= 0) continue;
            var inc: i64 = 1;
            if (tns.direction[w][filt] != 0) {
                inc = -1;
                start = end - 1;
            }
            start += @as(i64, @intCast(w)) * 128;
            var m: i64 = 0;
            while (m < size) : ({
                m += 1;
                start += inc;
            }) {
                var i: i64 = 1;
                while (i <= @min(m, order)) : (i += 1) {
                    coef[@intCast(start)] -= coef[@intCast(start - i * inc)] * lpc[@intCast(i - 1)];
                }
            }
        }
    }
}

/// imdct_and_windowing.
fn imdctAndWindowing(d: *Decoder, sce: *Sce) void {
    const ics = &sce.ics;
    const in = &sce.coeffs;
    const out = sce.out();
    const saved = &sce.saved;
    const swindow: []const f32 = if (ics.use_kb_window[0] != 0) &tab.kbd_short_128 else &tab.sine_128;
    const lwindow_prev: []const f32 = if (ics.use_kb_window[1] != 0) &tab.kbd_long_1024 else &tab.sine_1024;
    const swindow_prev: []const f32 = if (ics.use_kb_window[1] != 0) &tab.kbd_short_128 else &tab.sine_128;
    const buf = &d.buf_mdct;
    const temp = &d.temp;
    if (ics.window_sequence[0] == Window.eight_short) {
        var i: usize = 0;
        while (i < 1024) : (i += 128) d.mdct128.run(buf[i..][0..128], in[i..][0..128]);
    } else {
        d.mdct1024.run(buf, in);
    }
    const ws0 = ics.window_sequence[0];
    const ws1 = ics.window_sequence[1];
    if ((ws1 == Window.only_long or ws1 == Window.long_stop) and (ws0 == Window.only_long or ws0 == Window.long_start)) {
        float_dsp.fmulWindow(out[0..1024], saved[0..512], buf[0..512], lwindow_prev, 512);
    } else {
        @memcpy(out[0..448], saved[0..448]);
        if (ws0 == Window.eight_short) {
            float_dsp.fmulWindow(out[448 + 0 * 128 ..][0..128], saved[448..][0..64], buf[0 * 128 ..][0..64], swindow_prev, 64);
            float_dsp.fmulWindow(out[448 + 1 * 128 ..][0..128], buf[0 * 128 + 64 ..][0..64], buf[1 * 128 ..][0..64], swindow, 64);
            float_dsp.fmulWindow(out[448 + 2 * 128 ..][0..128], buf[1 * 128 + 64 ..][0..64], buf[2 * 128 ..][0..64], swindow, 64);
            float_dsp.fmulWindow(out[448 + 3 * 128 ..][0..128], buf[2 * 128 + 64 ..][0..64], buf[3 * 128 ..][0..64], swindow, 64);
            float_dsp.fmulWindow(temp[0..128], buf[3 * 128 + 64 ..][0..64], buf[4 * 128 ..][0..64], swindow, 64);
            @memcpy(out[448 + 4 * 128 ..][0..64], temp[0..64]);
        } else {
            float_dsp.fmulWindow(out[448..][0..128], saved[448..][0..64], buf[0..64], swindow_prev, 64);
            @memcpy(out[576..][0..448], buf[64..][0..448]);
        }
    }
    if (ws0 == Window.eight_short) {
        @memcpy(saved[0..64], temp[64..128]);
        float_dsp.fmulWindow(saved[64..][0..128], buf[4 * 128 + 64 ..][0..64], buf[5 * 128 ..][0..64], swindow, 64);
        float_dsp.fmulWindow(saved[192..][0..128], buf[5 * 128 + 64 ..][0..64], buf[6 * 128 ..][0..64], swindow, 64);
        float_dsp.fmulWindow(saved[320..][0..128], buf[6 * 128 + 64 ..][0..64], buf[7 * 128 ..][0..64], swindow, 64);
        @memcpy(saved[448..][0..64], buf[7 * 128 + 64 ..][0..64]);
    } else if (ws0 == Window.long_start) {
        @memcpy(saved[0..448], buf[512..][0..448]);
        @memcpy(saved[448..][0..64], buf[7 * 128 + 64 ..][0..64]);
    } else {
        @memcpy(saved[0..512], buf[512..][0..512]);
    }
}

const testing = std.testing;
const fixtures = @import("../testing/fixtures.zig");
const demux = @import("../format/demux.zig");
const aac = @import("../format/aac.zig");
const hostile = @import("../testing/hostile.zig");
const vectors = @embedFile("../testing/vectors/aac_decode.txt");
const demux_vectors = @embedFile("../testing/vectors/aac.txt");

/// The stream's rate and channels after FFmpeg's read-ahead (aac.txt's
/// `S` line), with which the oracle opens its decoder.
fn streamParams(name: []const u8) ![2]u32 {
    var start: usize = 0;
    while (std.mem.findPos(u8, demux_vectors, start, "F ")) |at| {
        const line_end = std.mem.findScalarPos(u8, demux_vectors, at, '\n') orelse demux_vectors.len;
        start = line_end;
        if (!std.mem.eql(u8, demux_vectors[at + 2 .. line_end], name)) continue;
        const s_at = std.mem.findPos(u8, demux_vectors, line_end, "\nS 0 ") orelse return error.MissingVector;
        var f = std.mem.tokenizeScalar(u8, demux_vectors[s_at + 1 ..], ' ');
        for (0..4) |_| _ = f.next();
        return .{ try std.fmt.parseInt(u32, f.next().?, 10), try std.fmt.parseInt(u32, f.next().?, 10) };
    }
    return error.MissingVector;
}

/// The vector lines of one fixture, after its `F` line.
fn vectorBlock(name: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.findPos(u8, vectors, start, "F ")) |at| {
        const line_end = std.mem.findScalarPos(u8, vectors, at, '\n') orelse vectors.len;
        const end = std.mem.findPos(u8, vectors, line_end, "\nF ") orelse vectors.len;
        if (std.mem.eql(u8, vectors[at + 2 .. line_end], name)) return vectors[line_end + 1 .. @min(end + 1, vectors.len)];
        start = end;
    }
    return null;
}

/// mp3_decode_vectors.c's lines for an ADTS fixture: each packet sent to
/// the decoder (a failure of its first decode is the send's), then each
/// frame's sample count and the MD5 of its float planes.
fn decodeVectorLines(gpa: std.mem.Allocator, name: []const u8, bytes: []const u8, out: *std.ArrayList(u8)) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    const dm = try aac.Demuxer.initSeekable(gpa, &reader, .fixed(&reader), .{});
    defer dm.deinit();
    var layer = demux.Layer(aac.Demuxer).init(gpa, dm);
    defer layer.deinit();
    try layer.findStreamInfo();
    try out.appendSlice(gpa, "O ok\n");
    const params = try streamParams(name);
    var d = try Decoder.init(gpa, params[0], params[1]);
    defer d.deinit();
    while (try layer.next()) |p| {
        var data = p.data;
        var sent = false;
        while (data.len != 0) {
            const got = d.decode(data) catch |err| {
                const code = switch (err) {
                    error.InvalidData => "INVALIDDATA",
                    error.Failed => "-1",
                    error.AdtsSync => "-16977930",
                    error.AdtsSampleRate => "-50531338",
                    error.AdtsFrameSize => "-67308554",
                    error.PatchWelcome => "-1163346256",
                    else => return err,
                };
                if (!sent) {
                    try out.print(gpa, "P {d} {s}\n", .{ p.data.len, code });
                    sent = true;
                } else try out.print(gpa, "E {s}\n", .{code});
                break;
            };
            data = data[@min(got.consumed, data.len)..];
            const frame = got.frame orelse continue;
            if (!sent) {
                try out.print(gpa, "P {d} 0\n", .{p.data.len});
                sent = true;
            }
            var md5: std.crypto.hash.Md5 = .init(.{});
            for (frame.planes) |plane| {
                for (plane) |v| {
                    var le: [4]u8 = undefined;
                    std.mem.writeInt(u32, &le, @bitCast(v), .little);
                    md5.update(&le);
                }
            }
            var digest: [16]u8 = undefined;
            md5.final(&digest);
            try out.print(gpa, "D {d} {x}\n", .{ frame.samples, &digest });
        }
        if (!sent) try out.print(gpa, "P {d} 0\n", .{p.data.len});
    }
}

test "every ADTS fixture decodes as FFmpeg's aac decoder decodes it (vectors/aac_decode.txt)" {
    const gpa = testing.allocator;
    var checked: usize = 0;
    inline for (fixtures.aac.all) |fixture| {
        // Main and LTP streams are refused (notes.md "AAC decoder
        // scope"), from their first frame.
        const other_profile = comptime for ([_][]const u8{ "aac_main_96k", "aac_ltp_7350_8ch" }) |n| {
            if (std.mem.eql(u8, n, fixture.name)) break true;
        } else false;
        if (comptime other_profile) {
            const bytes = fixtures.aac.bytes(fixture.name);
            var d = try Decoder.init(gpa, 0, 0);
            defer d.deinit();
            const first = try adts.parseHeader(bytes[0..adts.header_size]);
            try testing.expectError(error.UnsupportedFeature, d.decode(bytes[0..first.frame_length]));
            checked += 1;
        } else if (comptime fixture.expected == .accept) {
            const want = vectorBlock(fixture.name) orelse return error.MissingVector;
            var got: std.ArrayList(u8) = .empty;
            defer got.deinit(gpa);
            try decodeVectorLines(gpa, fixture.name, fixtures.aac.bytes(fixture.name), &got);
            testing.expectEqualStrings(want, got.items) catch |err| {
                std.debug.print("aac fixture {s}\n", .{fixture.name});
                return err;
            };
            checked += 1;
        }
    }
    try testing.expectEqual(44, checked);
}

/// apply_dependent_coupling (before the IMDCT) and
/// apply_independent_coupling (after it, `vector_fmac_scalar` over 1024
/// samples, 2048 with SBR).
fn applyCoupling(target: *Sce, cce: *ChannelElement, index: usize, dependent: bool, sbr: bool) void {
    if (!dependent) {
        const gain = cce.coup.gain[index][0];
        const len: usize = @as(usize, 1024) << @intFromBool(sbr);
        float_dsp.fmacScalar(target.out()[0..len], cce.ch[0].out()[0..len], gain);
        return;
    }
    const ics = &cce.ch[0].ics;
    const offsets = ics.swb_offset;
    var base: usize = 0;
    var idx: usize = 0;
    for (0..ics.num_window_groups) |g| {
        for (0..ics.max_sfb) |i| {
            defer idx += 1;
            if (cce.ch[0].band_type[idx] == BandType.zero) continue;
            const gain = cce.coup.gain[index][idx];
            for (0..ics.group_len[g]) |group| {
                for (offsets[i]..offsets[i + 1]) |k| {
                    const at = base + group * 128 + k;
                    target.coeffs[at] += gain * cce.ch[0].coeffs[at];
                }
            }
        }
        base += @as(usize, ics.group_len[g]) * 128;
    }
}

/// decode_cce (float): the coupling's targets, its channel stream, then
/// the gains (`GET_GAIN`: `powf(scale, -gain)`).
fn decodeCce(d: *Decoder, r: *bits.BitReader, che: *ChannelElement) Error!void {
    var num_gain: usize = 0;
    const sce = &che.ch[0];
    const coup = &che.coup;
    coup.coupling_point = 2 * @as(u32, r.bit());
    coup.num_coupled = r.bits(3);
    for (0..coup.num_coupled + 1) |c| {
        num_gain += 1;
        coup.type[c] = if (r.bit() != 0) .cpe else .sce;
        coup.id_select[c] = r.bits(4);
        if (coup.type[c] == .cpe) {
            coup.ch_select[c] = r.bits(2);
            if (coup.ch_select[c] == 3) num_gain += 1;
        } else coup.ch_select[c] = 2;
    }
    coup.coupling_point += @intFromBool(r.bit() != 0 or (coup.coupling_point >> 1) != 0);
    const sign = r.bit();
    const scale = cce_scale[r.bits(2)];
    try decodeIcsImpl(d, sce, r, false);
    for (0..num_gain) |c| {
        var idx: usize = 0;
        var cge: u1 = 1;
        var gain: i32 = 0;
        var gain_cache: f32 = 1.0;
        if (c != 0) {
            cge = if (coup.coupling_point == Coupling.after_imdct) 1 else r.bit();
            gain = if (cge != 0) scalefactorCode(r) - 60 else 0;
            gain_cache = libm.powf(scale, @floatFromInt(-gain));
        }
        if (coup.coupling_point == Coupling.after_imdct) {
            coup.gain[c][0] = gain_cache;
            continue;
        }
        for (0..sce.ics.num_window_groups) |_| {
            for (0..sce.ics.max_sfb) |_| {
                defer idx += 1;
                if (sce.band_type[idx] == BandType.zero) continue;
                if (cge == 0) {
                    var diff = scalefactorCode(r) - 60;
                    if (diff != 0) {
                        var s: i32 = 1;
                        gain += diff;
                        diff = gain;
                        if (sign != 0) {
                            s -= 2 * (diff & 1);
                            diff >>= 1;
                        }
                        gain_cache = libm.powf(scale, @floatFromInt(-diff)) * @as(f32, @floatFromInt(s));
                    }
                }
                coup.gain[c][idx] = gain_cache;
            }
        }
    }
}

// Fuzzing --------------------------------------------------------------

/// The container rates a fuzz input opens the decoder with: none, ADTS's,
/// and two it has no index for.
const fuzz_rates = [_]u32{ 0, 8000, 22050, 44100, 48000, 96000, 7350, 11000, 100000 };

/// A fuzz input's stream: up to 16 KiB of ADTS bytes (the first slice),
/// cut into packets at each ADTS header's frame length (the first value
/// 0; a byte that starts no header is a packet of one byte) or into raw
/// pieces of 1 to 4096 bytes (the second value); the decoder opened with
/// one of `fuzz_rates` (the third value) and 0 to 8 channels (the fourth).
/// Returns the frames decoded.
fn fuzzRun(smith: *std.testing.Smith) !u32 {
    const gpa = testing.allocator;
    var input: [16384 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const stream = input[0..len];
    const framed = smith.valueRangeAtMost(u8, 0, 1) == 0;
    const chunk = smith.valueRangeAtMost(u16, 1, 4096);
    const rate = fuzz_rates[smith.valueRangeAtMost(u8, 0, fuzz_rates.len - 1)];
    const channels = smith.valueRangeAtMost(u8, 0, 8);
    var d = Decoder.init(gpa, rate, channels) catch |err| return if (err == error.OutOfMemory) err else 0;
    defer d.deinit();
    var frames: u32 = 0;
    var at: usize = 0;
    while (at < stream.len) {
        var n: usize = @min(chunk, stream.len - at);
        if (framed) {
            n = 1;
            if (stream.len - at >= adts.header_size) {
                if (adts.parseHeader(stream[at..][0..adts.header_size])) |h| n = @min(h.frame_length, stream.len - at) else |_| {}
            }
        }
        // decode.c's loop over the packet.
        var data = stream[at..][0..n];
        at += n;
        while (data.len != 0) {
            const got = d.decode(data) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => break,
            };
            // A packet that consumed nothing and gave no frame would loop
            // forever in decode.c too.
            try testing.expect(got.consumed > 0 or got.frame != null);
            data = data[@min(got.consumed, data.len)..];
            const f = got.frame orelse continue;
            try testing.expect(f.samples == 1024 or f.samples == 2048);
            try testing.expect(f.planes.len > 0 and f.planes.len <= max_channels);
            for (f.planes) |plane| for (plane[0..f.samples]) |v| std.mem.doNotOptimizeAway(v);
            frames += 1;
            if (got.consumed == 0) break;
        }
    }
    return frames;
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    _ = try fuzzRun(smith);
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed(fixtures.aac.bytes("aac_ffmpeg_short"), &.{ 0, 4096, 3, 2 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_ffmpeg_mono_8k"), &.{ 0, 4096, 1, 1 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_ffmpeg_transients"), &.{ 1, 4096, 0, 0 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_ffmpeg_pns_22k"), &.{ 0, 4096, 2, 1 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_ffmpeg_is_ms"), &.{ 0, 333, 3, 2 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_ffmpeg_5point1"), &.{ 0, 4096, 4, 6 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_ffmpeg_7point1_wide"), &.{ 0, 4096, 4, 8 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_ffmpeg_96k_256k"), &.{ 1, 700, 5, 2 }),
    // SBR (T30c): stereo, mono output as stereo, transients, 5.1.
    hostile.fuzzSeed(fixtures.aac.bytes("aac_fdk_he_44k_stereo"), &.{ 0, 4096, 2, 2 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_fdk_he_48k_mono"), &.{ 0, 4096, 2, 1 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_fdk_he_32k_transients"), &.{ 1, 900, 0, 0 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_fdk_he_5point1"), &.{ 0, 4096, 4, 6 }),
    // Parametric stereo (T30d): 20 and 34 bands, IPD and OPD.
    hostile.fuzzSeed(fixtures.aac.bytes("aac_fdk_hev2_44k"), &.{ 0, 4096, 2, 1 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_fdk_hev2_32k_noise"), &.{ 0, 4096, 0, 0 }),
};

test "fuzz: the AAC decoder on arbitrary streams, framed or in raw pieces" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "every seed of the AAC decoder's fuzz entry decodes frames" {
    for (fuzz_corpus) |seed| {
        var smith: std.testing.Smith = .{ .in = seed };
        try testing.expect(try fuzzRun(&smith) > 0);
    }
}

test "mutation smoke: the AAC decoder on mutated seeds" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 48, 0x61616364);
}
